# paper2brain-client

把这台 Mac 接到 paper2brain 服务器（团队版，例如 https://www.paper2brain.cn）：网页上的 agent（Cursor，以及装了 `tcodex` 时的 TCodex）在这台 Mac 上运行，用你自己的 Cursor key；它们只能通过服务器的接口、按你的权限读写论文库。论文库本身、网页和所有服务代码都在服务器上，这里只有很少的、基本不变的代码，只用 Python 标准库。

## 接入

1. 打开服务器的邀请链接，写名字。
2. 网页左下角"Agent"设置 →"生成本机 agent 的口令"，照显示的命令运行：

   ```sh
   git clone https://github.com/jetteezhou/paper2brain-client ~/paper2brain-client
   ~/paper2brain-client/setup.sh https://www.paper2brain.cn <口令>
   ```

   `setup.sh` 问一次 Cursor API key 和快速搜索接口（这台 Mac 上已有单人版 paper2brain 的话直接沿用它的设置），把它们登记到服务器你自己的论文库里，并把 Cursor worker（和 TCodex）装成开机自启。可以重复运行；换 key 或接口时删掉 `~/.paper2brain-client/config.json` 里对应的项再运行。

## 里面有什么

- `./p2b`：agent 运行的命令。每条都发到服务器执行（`p2b_client/remote.py`）；`--file` / `--image` 的内容随命令一起发，插图和画好的图回传到 `~/.paper2brain-client/cache`，代码仓库在本机检出同一个 commit。
- `./p2b guide`：把服务器上当前的 `librarian/` 工作规范写到这里（服务器发来的每个任务都先运行它；`librarian/` 不进 git）。
- `p2b_client/tcodex_runner.py`：向服务器领取你的 TCodex 任务，在本机运行 `tcodex exec`，把回答边生成边传回。
- `ops/`：launchd 任务 `com.paper2brain.worker`、`com.paper2brain.tcodex`（日志 `/tmp/paper2brain-worker.log`、`/tmp/paper2brain-tcodex.log`）。

一台 Mac 只有一个 `com.paper2brain.worker`：装上这个之后，它替服务器干活，不再替本机的单人版 paper2brain 干活。

## 测试

```sh
python3 -m unittest discover -s tests
```
