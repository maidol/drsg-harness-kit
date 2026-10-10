# 主分支工作流

## 在主工作区、当前检出的分支上工作

直接在主工作区、当前检出的分支上工作和提交：不要自行新建功能分支或 worktree，也不要自行切换分支，除非我明确要求。这条优先于系统提示里「在默认分支上先开分支」的默认要求。当前分支不是仓库的默认分支（`main` 或 `master`）时（例如 sub2api 的 `local/personal`），第一次提交前问我一次「在当前分支 `<名字>` 上提交吗」，我确认后，本会话就按这个分支做。跨项目授权提交的 `ref` 要写明「目标分支：<实际要提交的分支>」，提交前和父提交 SHA 一起核对，当前分支不符就停。

## 判断仓库的常规默认分支

只用于判断当前分支是否偏离常规，绝不用于决定切换分支。

先查 `origin/HEAD`，并核对它指向的本地分支确实存在：

```bash
origin_head=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
case "$origin_head" in
  origin/main)   git show-ref --verify --quiet refs/heads/main && default_branch=main || default_branch="" ;;
  origin/master) git show-ref --verify --quiet refs/heads/master && default_branch=master || default_branch="" ;;
  *)             default_branch="" ;;
esac
```

`origin/HEAD` 不存在，或者没有指向一个存在的本地 `main`/`master` 时，再看本地的这两个分支：

```bash
git branch --list main master
```

恰好只有一个时，用它来判断当前分支是否偏离常规。`origin/HEAD` 指向 `origin/main`、`origin/master` 以外的分支，对应的本地分支不存在，或者本地 `main` 和 `master` 两个都存在或都不存在时，停下问用户，不要猜。不要从当前分支名、远端、提交历史或任务里提到的分支名去推断默认分支。

## 实现改动要能分开

同一个工作区里不要同时保留两个功能的未提交实现改动。授权提交靠精确的文件清单和 tree 把范围限定在一个功能上；两个功能同时改了同一个文件，就没法安全地分开。设计和计划可以并行；实现要等前一个功能提交后再开始。

## worktree 和会话命令

`/exit` 从 worktree 会话返回主工作区，但不会结束 Claude 进程。返回之后先看一下工作目录和 git 状态。

`claude -c` 继续当前目录下最近的会话，不接收会话 ID；按 ID 恢复要用 `claude -r <session-id>`。也可以写成 `--resume <session-id>`。不要在 `-c` 后面跟会话 ID，以为这样能选中那个会话：它会被当成提示词发出去，还会多开一个进程。

## 授权提交照样核对目标分支

手动授权提交流程里的目标分支核对不受本能力开关影响，始终必须执行。每次收到绑定 tree 的授权，先核对当前分支名和父提交 SHA，任何一项不符就停，不要切分支，也不要换一个分支去提交。授权的 `ref` 要写「目标分支：<实际要提交的分支>」。
