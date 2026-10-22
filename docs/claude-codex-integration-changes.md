# Claude / Codex 联动：改动说明

本文记录这一轮对「胡闹AutoDL」（macOS 版）做的全部改动：代码、测试、文档，以及我在你机器和服务器上实际执行过的操作。

## 1. 目标

之前让 Claude Code / Codex 去 AutoDL 实例上干活，每次都要：

- 把 `ssh -p <端口> root@connect.<区>.seetacloud.com` 贴给它；
- 遇到只能密码登录的实例，它要现写 askpass / expect 脚本（对话记录里出现过 700 多次）；
- 上传文件时常把内容拼进 ssh 命令，既耗 token，输出又冗长。

现在胡闹AutoDL 在后台持续维护三样东西：

1. **SSH 别名**（`~/.ssh/hunao_autodl.conf`）：`ssh autodl-<实例名>` 就能连；
2. **免密登录**：实例开机后自动检测，不通就用接口返回的 root 密码一次性装好公钥；
3. **说明段**：把「开着哪台、怎么连、注意什么」写进 `~/.claude/CLAUDE.md` 和 `~/.codex/AGENTS.md` 里带标记的一段。

新开一个终端启动 `claude` 或 `codex`，直接说「在 4090 那台上跑 xxx」即可。

## 2. 改动总览

> 说明：`git status` 里还有很多修改（`AppModel.swift`、`AutoDLAPI.swift`、`AccountMonitor.swift` 等）。那些里有一部分是我开始之前就已存在的未提交工作（多账号支持等）。下表只列**我这一轮碰过的文件**。本轮没有提交任何东西。

### 新增文件

| 文件 | 行数 | 作用 |
| --- | --- | --- |
| `Sources/SSHConfigManager.swift` | 341 | 纯逻辑：解析 `ssh_command`、别名、渲染托管配置、Include、known_hosts 判断、说明段渲染与替换 |
| `Sources/SSHAccess.swift` | 272 | `ProcessRunner`（共用进程执行）、免密检测与配置 |
| `Sources/AgentContextWriter.swift` | 136 | 文件落地：原子写入、保留权限、跟随符号链接、写 ssh 配置和说明文件 |
| `Sources/AgentIntegration.swift` | 414 | 协调器：汇总所有账号的实例、串行化同步、维护每台实例的免密状态机 |
| `Tests/SSHConfigTests.swift` | 511 | 离线测试，159 项检查 |
| `scripts/test-ssh.sh` | 18 | 运行上面的测试 |
| `docs/claude-codex-integration-changes.md` | — | 本文 |

> `SSHConfigManager.swift` 在上一轮已有雏形（解析、别名、渲染等纯逻辑），本轮做了较大修订，见 3.1。

### 修改文件

| 文件 | 改动 |
| --- | --- |
| `Sources/Models.swift` | `AutoDLInstance` 新增 `startMode` 字段、`isNoCardMode` 属性，解析 `start_mode` |
| `Sources/AccountMonitor.swift` | 实例变化时通知 AppModel；新增 `isSettledForAgent` |
| `Sources/AppModel.swift` | 持有 `AgentIntegration`；汇总各账号数据并触发同步；演示模式接入 |
| `Sources/HuNaoAutoDLApp.swift` | 把 `agent` 注入 SwiftUI 环境 |
| `Sources/Views/InstancesView.swift` | 实例卡片新增别名 + 免密状态行；无卡模式显示 |
| `Sources/Views/SettingsView.swift` | 新增「Claude / Codex」卡片和首次开启的确认弹窗 |
| `Sources/Theme.swift` | 新增 `AppClipboard.copy(_:)` |
| `Sources/UpdateService.swift` | `runProcess` 改为委托给共用的 `ProcessRunner` |
| `Sources/DemoData.swift` | 两个已关机的演示实例补上 `sshCommand` |
| `README.md` | 新增功能行、第 8 节使用说明、隐私说明、项目结构 |

没有改动：Windows 版（`windows/`）、AutoDL 接口封装（`AutoDLAPI.swift`）、构建脚本。

## 3. 各模块详解

### 3.1 `SSHConfigManager.swift`：纯逻辑层

全部是不碰文件系统的纯函数，所以能被离线测试覆盖。

- **`SSHEndpoint.parse`**：从 `ssh -p 54635 root@connect.weste.seetacloud.com` 取出主机、端口、用户。支持 `-p 123` 与 `-p123`、缺省端口 22、多余空白，拒绝无目标、空用户、端口越界。两种 AutoDL 形式（`connect.*.seetacloud.com`、`region-N.autodl.pro`）都有测试。
- **`knownHostsKey`**：端口为 22 时是 `host`，否则是 `[host]:port`（OpenSSH 在 known_hosts 里的写法）。
- **别名 `aliases(for:)`**：`autodl-<实例名>`，实例名转小写，非 `[a-z0-9-]` 的字符变成 `-`，连续的 `-` 合并并去掉首尾。名字清洗后为空（例如纯中文名）时用实例 ID 后 8 位。

  本轮重写了重名处理：上一版依赖实例遍历顺序，API 返回顺序一变，重名实例的别名就会互换。现在结果**与顺序无关**：先按基础名分组，唯一的保持原名；重名的加账号名后缀，仍冲突再加实例 ID 后缀。名叫 `target` 的实例不会占用保留别名 `autodl-target`。
- **字符集**：上一版还允许 `_` 和 `.`，本轮改成计划里规定的 `[a-z0-9-]`。
- **监控目标别名**：固定别名默认 `autodl`；如果你自己的 `~/.ssh/config` 里已有 `Host autodl`（`configDefinesHost` 检测，不区分关键字大小写、忽略注释、能识别同一行里的多个别名），就改用 `autodl-target`。你的 `Host autodl` 因此完全不受影响。
- **`render`**：生成托管配置，每个 Host 含 `HostName`、`Port`、`User`、`IdentityFile ~/.ssh/id_ed25519`、`IdentitiesOnly yes`、`AddKeysToAgent yes`、`UseKeychain yes`（见 5.3）、`StrictHostKeyChecking accept-new`、`UserKnownHostsFile ~/.ssh/hunao_known_hosts`、`ServerAliveInterval 30`、`ServerAliveCountMax 3`、`ControlMaster auto`、`ControlPath ~/.ssh/cm-%C`、`ControlPersist 10m`。文件末尾加 `Match all`，让 Include 之后你自己配置里的全局行仍然对其他主机生效（已用真实 `ssh -G` 验证）。
- **主机密钥失效判断**：托管文件里每个 Host 记了 `# instance <ID>`。下次同步时，如果某个 host:port 现在属于另一台实例（AutoDL 会复用端口），`staleKnownHostsKeys` 就判定旧主机密钥失效。上一版计划另有一个按文本删除 known_hosts 行的函数，本轮删掉了，改用 `ssh-keygen -R`（能处理哈希过的 known_hosts）。
- **`addingInclude`**：在 `~/.ssh/config` 最前面加 `Include ~/.ssh/hunao_autodl.conf`。已存在则返回 nil（幂等）；被注释掉的不算已存在。
- **`AgentContextBlock`**：渲染说明段，并提供 `applying(_:to:)`：标记段不存在就追加，已存在就原位替换，传 nil 就删除；标记之外的内容一律不动，两侧空行处理稳定。
- **`SSHKeyStatus`**：`unknown / checking / ready / needsSetup / installing / unreachable / failed`。`contextNote` 把几种过渡状态合并成同一句话（「免密检测中」），这样检测进行中不会反复改写 CLAUDE.md。

### 3.2 `SSHAccess.swift`：进程执行与免密

**`ProcessRunner`**（从 `UpdateService.runProcess` 抽出，并增强）：

- 标准输出/错误写到**临时文件**，不用管道。原因：`ControlPersist` 会让 ssh 留下一个后台 master 进程，它继承管道后，读取端永远收不到 EOF，调用会卡死。测试里专门构造了「后台子进程占着 stdout」的情况。
- 支持超时：先 `terminate`，2 秒后还不退出就 `SIGKILL`。
- 支持传入环境变量（用来传密码，见下）。
- 同步版 `runSync` 与异步版 `run`（放到后台线程）。

**检测 `check(alias:)`**：执行 `ssh -o BatchMode=yes -o ConnectTimeout=8 <别名> true`，由 `classify` 把结果归类：

| 结果 | 状态 |
| --- | --- |
| 退出码 0 | `ready` |
| 输出含 `permission denied` / `too many authentication failures` | `needsSetup` |
| 主机密钥不一致 | `failed`（提示检查 `hunao_known_hosts`） |
| 超时、拒绝连接、DNS 失败等 | `unreachable`（实例刚开机，sshd 可能还没起） |

**配置 `install(alias:password:)`**：

1. `ensurePublicKey`：没有 `~/.ssh/id_ed25519` 就 `ssh-keygen -t ed25519` 生成；有私钥没公钥就用 `ssh-keygen -y` 推导；再校验公钥格式。
2. `askpassURL`：在 `~/Library/Application Support/HuNaoAutoDL/ssh-askpass.sh` 写一个**内容固定、不含密码**的脚本（`printf '%s\n' "$HUNAO_SSH_PASSWORD"`），权限 0700。
3. 以 `SSH_ASKPASS_REQUIRE=force`、`HUNAO_SSH_PASSWORD=<密码>` 环境变量执行 ssh 密码登录，并带 `PubkeyAuthentication=no`、`ControlMaster=no`、`ControlPath=none`（密码会话不能变成或复用共享的 master 连接）。
4. 远端命令（`installCommand`）：`umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '<key>' … || printf … >> …; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys`。公钥用 `shellQuote` 转义，已有测试证明含单引号、分号、`$(…)` 的内容不会被 shell 解释，重复执行只追加一次，已有密钥保留，宽松的权限会被修正。

密码**只**存在于接口返回值、内存和 ssh 子进程的环境变量里：不在命令行参数中，不写文件，不进日志。

**`keyNeedsPassphrase` + `passphraseHint`**：见 5.3。

### 3.3 `AgentContextWriter.swift`：文件落地

`AgentFiles` 的所有路径都相对于传入的 `home`，因此测试可以在临时目录里跑，不碰真实 HOME。

- **`writeIfChanged`**：内容没变就不写（测试断言第二次同步后所有文件的修改时间都没变）；写入是原子的；保留已有文件的权限，新文件用默认权限（托管配置 0600，说明文件 0644）；**会跟随符号链接**，写的是链接指向的真实文件，链接本身保留；文件不是合法 UTF-8 时直接报错、不覆盖。
- **`apply(plan, home)`** 的顺序：确保 `~/.ssh` 存在 → 读旧的托管文件 → 写新的托管文件 → 对失效的 host:port 执行 `ssh-keygen -R`（并清理它留下的 `.old`）→ 确保 Include 行（先备份 `config.hunao-backup`，缺 `~/.ssh/config` 时创建一个只含 Include 的）→ 写两个说明文件。
- **说明文件只在工具已安装时才写**：`~/.claude` 或 `~/.codex` 目录不存在就跳过，不替你创建目录。目录存在但文件不存在，则创建文件。
- **`removeContext`**：关闭总开关时只删标记段，Include 行保留。

### 3.4 `AgentIntegration.swift`：协调器

一个 `@MainActor` 的 `ObservableObject`，由 `AppModel` 持有。

**输入**：`AgentAccountInput`（账号 ID、名称、实例列表、监控目标、是否当前账号、是否已「落定」）。

**开关**（存在 UserDefaults，键名沿用 `hunao.` 前缀）：`hunao.agentContextEnabled`（总开关，默认关）、`hunao.sshAutoSetup`（自动配置免密，默认开）、`hunao.agentContextConfirmed`（是否已确认过首次弹窗）。

**同步流程**：

1. `update(accounts:)` 保存最新输入，并安排一次同步，带 0.4 秒去抖。
2. 同步严格串行：同步进行中又来请求，只记一个「需要再跑一遍」的标记。
3. 所有账号都「落定」后才写（启动时有的账号还没拉到实例列表，此时不写，避免用残缺列表覆盖文件）。
4. 生成快照（`makeSnapshot`，纯函数、已测试）；与上次写入的内容比较，没变就不写。
5. 在后台线程执行文件写入；失败时把原因放进 `lastError`，设置页会显示。
6. 然后推进各实例的免密状态机。

**`makeSnapshot` 的细节**：

- 同一台实例出现在多个账号里时按实例 ID 去重，先出现的账号优先（见 5.1）。
- 监控目标别名只给**当前显示账号**的监控目标，并且该实例必须有 SSH 地址。
- 实例按别名（无地址的按名称）排序，输出与 API 返回顺序无关。
- 只有一个账号时说明段里不出现账号名。
- 没有 SSH 地址的实例（例如刚创建）不会被写出别名，已关机的只按名称列在「未运行」里。

**免密状态机**（按实例）：

- 只对「运行中且有 SSH 地址」的实例工作。状态绑定到一个签名（`host:port` + 密码的哈希）；实例关机、换了地址或换了密码，状态就重置，下次重新检测。
- `unknown` → 检测 →  `ready` / `needsSetup` / `unreachable`。
- `unreachable` 每 20 秒重试一次，最多 12 次（对应刚开机 sshd 还没起来的情况）。
- `needsSetup` 且开启了自动配置、接口给了密码 → 自动配置**一次**；成功后再检测一次确认。
- 自动配置失败（`failed`）**不会自动重试**，避免反复用错误的密码去撞服务器；用户可在实例卡片上点「配置免密」手动重试。
- 成功/失败通过 `notify` 弹 toast（即 AppModel 的 `presentToast`）。

**轮询驱动**：没有额外的定时器。每个账号的每次轮询（默认 15 秒）都会触发一次 `update`，状态机的重试靠这个节奏推进；内容没变时整个同步只是一次内存比较和一次小文件读取。

**演示模式**：`applyDemo` 只计算别名和状态，不碰任何文件、不执行 ssh。

### 3.5 AppModel / AccountMonitor 联动

- `AccountMonitor` 在 `applyInstances`（每次轮询）、`selectInstance`、`rename`、`expire` 之后调用 `app?.syncAgentContext()`。
- 新增 `isSettledForAgent`：已拉到实例列表，或鉴权失败，或已报错，才算「落定」。
- `AppModel` 新增 `agent`、`agentInputs()`、`syncAgentContext()`；在切换账号、移除账号后也会同步；账号全部移除时会写入「当前没有正在运行的实例」。
- 初始化顺序注意：`notify` 闭包必须在所有存储属性初始化完之后再赋值（见 5.5）。

### 3.6 无卡模式（`Models.swift` 等）

- AutoDL 接口用 `start_mode` 区分启动方式：`gpu` 为正常，`non_gpu` 为无卡模式；关机后该字段保留上一次的值。
- `isNoCardMode = (start_mode == non_gpu) && 实例运行中或启动中`，所以已关机的实例仍按正常规格显示。
- **为什么需要**：无卡模式下接口仍返回 `req_gpu_amount = 1`，原来会写成「RTX 6000D ×1」，Claude 会以为有卡。
- 说明段里写成「无卡模式（没有 GPU，内存仅 2.0 GB）」，并在有运行中的无卡实例时多加一条提示：不要跑训练/推理，要 GPU 请提醒用户用正常模式重新开机（数据盘保留）。内存数字来自接口的 `mem_limit`。
- 实例卡片上 GPU 那一格显示「无卡模式」，鼠标悬停可看原规格。

### 3.7 界面

- **实例卡片**（`InstancesView.swift`）：在原有信息下多一行，显示 `autodl-xxx · 免密 ✓`。点击复制 `ssh <别名>`（并弹 toast）；状态为「免密待配置」或「免密配置失败」时出现「配置免密」小按钮。状态文案：`免密 ✓ / 免密待配置 / 检测中 / 正在配置免密 / 暂时连不上 / 免密配置失败 / 未开机`。总开关关闭时这一行不显示。没有加其他按钮，避免误触。
- **设置页**（`SettingsView.swift`）：新增「Claude / Codex」卡片，放在右列「监控与自动开机」之后：总开关、自动配置免密开关（总开关关闭时置灰）、托管配置路径、已写入实例数、监控目标别名、错误信息、「只影响之后新启动的会话」的说明。**第一次打开总开关会弹窗**，列出会做的事：Include（先备份）、托管配置、说明段、自动配免密（密码不落盘）；关闭开关会删除说明段。
- **`AppClipboard.copy`**（`Theme.swift`，紧挨 `AppLinks`）。

### 3.8 其他

- **`UpdateService.runProcess`**：改为调用 `ProcessRunner.runSync`。注意行为有两处细微变化：输出走临时文件；增加了 600 秒超时（原来没有超时）。
- **`DemoData.swift`**：两个已关机的演示实例补上 `sshCommand`，让演示截图里能看到别名。
- **演示模式新参数**：`--demo-key=needs` 让演示里的运行中实例显示「免密待配置」。

## 4. 对 token 的影响（对应你最关心的点）

**确定省掉的**：

- 不用再贴 ssh 命令（别名和端口都在说明里）；
- 不用再写 askpass / expect / sshpass 脚本；
- 连不上时少走弯路（说明里有判断方法）；
- 连接复用（`ControlMaster`）。

**原来没解决的**：Claude 习惯把文件内容拼进 ssh 命令（`ssh host 'cat > f' <<EOF …`）。内容要穿过它的上下文，进度条和 pip 日志也会冲进去。配好免密并不能改变这个习惯，所以说明段里新增了「省 token」一条：

> 传文件用 `rsync -azq`（没有就 `scp -qr`），别把文件内容塞进 ssh 命令或 heredoc；多条命令合成一次 ssh；长任务 `nohup … >log 2>&1 &`，只 `tail -n 20 log`；pip/git/wget 加 `-q`。

**说明段本身的开销**：这一段会在**每个** claude / codex 会话里加载，包括跟 AutoDL 无关的会话。所以我把整段压短：有无卡实例和省 token 提示时约 690 字（压缩前同样内容约 700 字，且还没有省 token 一条）；测试里加了「小于 800 字」的上限。

**效果**：见 6.3 的两次实测。但没有「改动前」的对照数据，所以不能说具体省了多少 token。

## 5. 过程中发现并修复的问题

### 5.1 同一实例出现在两个账号时 app 崩溃

演示模式启动即崩溃，错误是 `Duplicate values for key`。原因：`AgentIntegration` 里用了 `Dictionary(uniqueKeysWithValues:)`，而演示数据里同一台实例出现在两个账号。**真实使用中也会发生**（主账号和子账号都能看到同一台实例）。修复：按实例 ID 去重，先出现的账号优先；字典构造改用 `uniquingKeysWith`；补了回归测试。

### 5.2 重名实例的别名依赖顺序

见 3.1。API 返回顺序一变，别名会互换，导致说明和已存在的会话对不上。现已与顺序无关，并有正反两种顺序的测试。

### 5.3 私钥有密码短语时，配好免密后仍连不上

在你的真实实例上暴露：公钥已写入、服务器也接受了这把公钥（`Server accepts key`），但私钥有密码短语、ssh-agent 是空的，而 `BatchMode` 下 ssh 无法提示输入。你自己的 `~/.ssh/config` 里有 `AddKeysToAgent yes` / `UseKeychain yes`，说明密码短语在钥匙串里，只是我生成的托管配置没带这两项。

修复：托管配置加 `AddKeysToAgent yes` 和 `UseKeychain yes`；并新增 `keyNeedsPassphrase`，如果安装后仍然失败且私钥需要密码短语，错误提示会直接说明并给出 `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`。已验证：把 key 从 agent 移除后，普通 `ssh -o BatchMode=yes <别名>` 能自动从钥匙串恢复并连上。

### 5.4 无卡模式被写成有 GPU

见 3.6。

### 5.5 构建时才暴露的初始化顺序错误

`AppModel.init` 里 `notify` 闭包捕获 `self` 太早，`swiftc -typecheck` 查不出来（它不做确定性初始化检查），完整构建才报错。已挪到所有存储属性初始化之后。

### 5.6 我自己的两处失误（已更正）

- **无效的密码泄漏检查**：我曾运行过一次检查，想确认 root 密码没写进任何文件，但取密码的脚本失败，密码变量为空，`grep -F ""` 匹配了所有文件，输出毫无意义。我当时没有把它当结论，随后用有长度保护的版本重做：12 位的密码在所有相关文件里都找不到。
- **一次全屏截图**：做界面验证时，第一次误截了整个桌面（含与本项目无关的窗口）。该文件随即删除，之后都只用窗口 ID 截取演示窗口。

## 6. 测试与验证

### 6.1 自动化测试

| 脚本 | 检查项 |
| --- | --- |
| `scripts/test-accounts.sh` | 12（已有） |
| `scripts/test-sub-account.sh` | 22（已有） |
| `scripts/test-ssh.sh` | **159（新增）** |

`test-ssh.sh` 不联网、不碰真实 HOME，覆盖：

- 解析：两种 AutoDL 命令形式、边界输入；
- 别名：清洗、中文名、重名、顺序无关、保留别名；
- 渲染：稳定性、所有选项、`Match all`；
- Include：幂等、保留原文、注释不算；
- 标记段：首次插入、替换、重复应用、两侧内容保留、删除；
- known_hosts 失效判断；
- 用户配置冲突检测；
- `ssh` 结果归类；
- `ProcessRunner`：输出捕获、超时杀进程、环境变量、后台子进程不挂住调用；
- 远端安装命令：真的用 `/bin/sh` 在临时 HOME 里执行，验证重复执行只追加一次、不被 shell 解释、权限修正；
- askpass 脚本：用含 `' " $ \` \\ ! *` 的密码验证原样输出；
- 多账号快照：目标别名、账号名显示、无地址实例、密码不出现、去重、顺序无关；
- 无卡模式：解析、措辞、提示行只在运行中的无卡实例出现；
- 文件落地：在临时 HOME 里完整跑一遍，包括未变更不写、权限保留、备份、`ssh-keygen -R` 真实清理、符号链接保留、未安装的工具不创建目录、非 UTF-8 拒写。

### 6.2 其他验证

- 用真实 `ssh -G` 验证渲染出的配置：别名解析正确、`autodl-target` 指向同一台、你原有的 `Host autodl` 不受影响、Include 之后的全局配置仍生效。
- 完整构建 `build-app.sh`（构建到临时目录，**没有**覆盖你正在运行的 `dist/胡闹AutoDL.app`）。
- 演示模式截图：实例卡片（已配置 / 待配置 / 未开机）、设置页新卡片。

### 6.3 真机验证（在你开着的 `deja view1` 上）

我写了一个临时小程序，直接调用同一套 `AgentIntegration` 代码，读取你真实账号的实例，写真实文件、配置真实免密——效果等同于你把开关打开，但不会再启动第二份 app（避免重复轮询，也不涉及自动开机逻辑）。

- 免密：先因 5.3 失败，修复后成功，状态 `免密 ✓`。
- 全新 Claude 会话，**不给任何连接信息**，问「我现在开着哪台 AutoDL？连上去执行 hostname，并告诉我它有没有 GPU」：它自己认出 `autodl-deja-view1`，执行 hostname，并正确说明没有 GPU（`nvidia-smi` 报 `Permission denied`）；2 轮，约 $0.008。
- 全新 Claude 会话，让它把一个 30 文件、约 200 KB 的目录传上去并核对：它用了 `rsync -azq … || scp -qr …` 一条命令，核对在同一次调用里；3 轮，约 $0.057。我另外在服务器上核对：30 个文件，`du -sb` 203259 字节（含目录项）；服务器上有 rsync。测试目录已删除，只删了我自己建的 `/root/autodl-tmp/upload-test`。
- 整个过程跑了约 4 次 `claude -p` 会话，合计费用在 $0.1 量级。

## 7. 在你机器和服务器上实际改了什么

### 本机

| 位置 | 变化 | 备注 |
| --- | --- | --- |
| `~/.ssh/config` | 最前面加 3 行（注释 + `Include ~/.ssh/hunao_autodl.conf` + 空行） | 原文件备份在 `~/.ssh/config.hunao-backup`；diff 只有新增行 |
| `~/.ssh/hunao_autodl.conf` | 新建，0600 | 托管别名 |
| `~/.ssh/hunao_known_hosts` | 新建（ssh 自己写入） | 单独的主机密钥文件，不碰原 `known_hosts` |
| `~/.claude/CLAUDE.md` | 新建，只含标记段 | |
| `~/.codex/AGENTS.md` | 在原有内容后追加标记段 | 你原有的文字原样保留（块前 1299 字节 = 原 1297 + 2 个换行分隔） |
| `~/Library/Application Support/HuNaoAutoDL/ssh-askpass.sh` | 新建，0700 | 内容固定，不含密码 |
| ssh-agent | 验证时我执行过一次 `ssh-add -d` 移除 key，随后的验证连接又通过钥匙串把它加载回来 | |

### 服务器（`deja view1`）

- `/root/.ssh/authorized_keys` 追加了你的公钥（`~/.ssh/id_ed25519.pub`，你原有的那把）。
- 创建并删除了 `/root/autodl-tmp/upload-test`。

### 接口调用

用你 app 里保存的 Token，对 `https://www.autodl.com/api/v1/instance` 发起了几次**只读**请求（列出实例），Token 只放在请求头里，输出中已隐去密码类字段。

### 状态说明

- 你**正在运行的 app 仍是旧版本**，设置里的总开关是关的（它在自己的 UserDefaults 里，我没有改）。我的临时程序用的是它自己的 UserDefaults 域。
- 所以上面写入的说明段**目前不会自动更新**：`deja view1` 一关机，`CLAUDE.md` 里仍会写着它在运行。要持续自动更新，需要退出旧 app，运行 `zsh HuNaoAutoDL/scripts/build-app.sh` 重新构建，再在设置里打开开关。

## 8. 如何撤销

1. **说明段**：在新版 app 里关闭总开关即可；或手动删除 `<!-- hunao-autodl:start -->` 到 `<!-- hunao-autodl:end -->` 之间的内容。`~/.claude/CLAUDE.md` 是新建的，里面只有这一段，可直接删除。
2. **ssh 配置**：`cp ~/.ssh/config.hunao-backup ~/.ssh/config`，再删除 `~/.ssh/hunao_autodl.conf` 和 `~/.ssh/hunao_known_hosts`。
3. **askpass 脚本**：删除 `~/Library/Application Support/HuNaoAutoDL/ssh-askpass.sh`。
4. **服务器上的公钥**：登录实例，从 `/root/.ssh/authorized_keys` 删掉那一行（你的公钥）。

## 9. 已知限制与未做的事

- **说明段只影响之后新启动的会话**，已经开着的 claude / codex 不会刷新。
- **「省 token」只是提示，不是强制**，Claude 可能不照做。
- **服务器没有 rsync 时**依赖 `scp -qr` 作为备选；你的实例上有 rsync（已确认）。
- **2 GB 内存上限**来自接口的 `mem_limit`，我没有在容器内单独验证（`free` 显示的是宿主机内存）。
- **私钥没有放进钥匙串**的用户，第一次需要手动 `ssh-add --apple-use-keychain`；app 会给出提示。
- **没有做以无卡模式开机的功能**：我没有找到可靠的接口参数，不想猜。需要的话，需要抓一次 AutoDL 网页「无卡模式开机」发出的请求再接入。
- **按计划不做**：代理隧道开关、终端菜单、单独的服务器清单文件。
- **只有 macOS 版**，Windows 版没有改动。
- **没有提交 git**，所有改动都在工作区。

## 10. 与原计划的差异

- 协调逻辑单独放在 `AgentIntegration.swift`，而不是塞进 `AppModel`；`AgentContextWriter.swift` 只负责文件读写。
- 清理旧主机密钥用 `ssh-keygen -R`（计划里也是这样），并删除了此前版本里按文本删行的函数。
- `ProcessRunner` 用临时文件而不是管道接输出（原计划只说「参考 `runProcess` 抽成共用」）。
- 说明段里不再带时间戳（计划示例里有「10-21 14:32」），避免内容每次都变而反复改写文件。
- 新增计划里没有的内容：无卡模式识别、`AddKeysToAgent` / `UseKeychain`、私钥密码短语提示、按实例 ID 去重、「省 token」提示。
