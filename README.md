# paper2brain-client

把这台 Mac 接到 paper2brain 服务器（团队版，例如 https://www.paper2brain.cn）：网页上的 agent（Cursor，以及装了 `tcodex` 时的 TCodex）在这台 Mac 上运行：由这台 Mac 用你自己的 Cursor key 调用 Cursor（Cursor 按调用方所在地区提供模型，服务器在国内也不受影响；key 不上传服务器）；它们只能通过服务器的接口、按你的权限读写论文库。论文库本身、网页和所有服务代码都在服务器上，这里只有很少的、基本不变的代码，只用 Python 标准库。

## 接入

1. 打开服务器的邀请链接，写名字。
2. 网页左下角"Agent"设置 →"生成本机 agent 的口令"，照显示的命令运行：

   ```sh
   git clone https://github.com/jetteezhou/paper2brain-client ~/paper2brain-client
   ~/paper2brain-client/setup.sh https://www.paper2brain.cn <口令>
   ```

   `setup.sh` 问一次 Cursor API key 和快速搜索接口（这台 Mac 上已有单人版 paper2brain 的话直接沿用它的设置）：key 只存在这台 Mac 上，快速搜索接口登记到服务器你自己的论文库里；再把 Cursor worker 和 runner 装成开机自启。可以重复运行；换 Cursor key 时删掉 `~/.paper2brain-client/config.json` 里对应的项再运行。换快速搜索接口直接在网页左下角"Agent"设置里改，runner 会写进本机 config 并立即生效（key 不上传保存在服务器）。

## p2bot（默认关闭）

网页个人库里的 p2bot 模块：你在网页上写下任务（做 PPT、整理文档、跑脚本……），这台 Mac 去做，做完把文件交回网页下载。要用的话先在这台 Mac 上开启（会要求确认）：

```sh
cd ~/paper2brain-client && git pull && ./setup.sh --bot
```

- 扫描项目、照网页上确认过的计划挪文件、撤销：runner 直接运行服务器下发的 `p2b-tools.py`（临时目录里，不经过模型、不花 token）。
- 任务只跑 TCodex 或 DeepSeek Harness；每个任务一个工作目录 `~/p2bot/<任务>/`（附件在 `inputs/`），追问还在同一个目录里、接着同一个会话。
- 和论文库隔离：不在本仓库目录里运行，读不到 `librarian/`，环境里没有本机的 paper2brain 口令（`P2B_TOKEN` 等），只有这一轮专用的上传口令，这一轮结束后就失效；agent 用 `p2bot put <文件>` 交付。
- **不开沙箱**：agent 能读写这台 Mac 上的文件、联网、运行命令。规范要求它不碰 `~/paper2brain*` 和各种口令，但这只是规范，不是硬隔离。
- 关掉：删掉 `~/.paper2brain-client/config.json` 里的 `"p2bot": true`，再 `launchctl kickstart -k gui/$(id -u)/com.paper2brain.runner`。

## 里面有什么

- `./p2b`：agent 运行的命令。每条都发到服务器执行（`p2b_client/remote.py`）；`--file` / `--image` 的内容随命令一起发，插图和画好的图回传到 `~/.paper2brain-client/cache`，代码仓库在本机检出同一个 commit。
- `./p2b guide`：把服务器上当前的 `librarian/` 工作规范写到这里（服务器发来的每个任务都先运行它；`librarian/` 不进 git）。
- `p2b_client/runner.py`：向服务器领取你的任务。Cursor 的任务用本机的 key 调用 Cursor 创建或续上 agent（agent 在本机 worker 上干活），TCodex 的任务在本机运行 `tcodex exec`；回答边生成边传回，网页上停止时这边也停。它还把你的 Cursor 账户能用的模型告诉服务器。
- `ops/`：launchd 任务 `com.paper2brain.worker`、`com.paper2brain.runner`（日志 `/tmp/paper2brain-worker.log`、`/tmp/paper2brain-runner.log`）。

一台 Mac 只有一个 `com.paper2brain.worker`：装上这个之后，它替服务器干活，不再替本机的单人版 paper2brain 干活。

## 测试

```sh
python3 -m unittest discover -s tests
```
