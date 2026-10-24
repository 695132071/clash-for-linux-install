#!/usr/bin/env bash

# shellcheck disable=SC1091  # 独立 source（测试）时补载依赖；经 clashctl.sh 加载时已存在。
declare -F _clashctl_run_in_bash >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lib/shell.sh"

# 下载后的源码由本版本入口接管，旧更新器无需知道私有模块的位置。
_update_apply_source() {
    . "$1/scripts/install-common.sh" || return 1
    _install_validate_source "$1" || return 1
    _install_apply_update "$@"
}

clashupdate() {
    case ${1:-} in
    -h | --help)
        printf '用法: clashupdate\n更新 clashctl 的脚本与资源，保留用户配置和内核。来源由 .env 中 CLASHCTL_UPDATE_BRANCH 和 GH_PROXY 配置。\n'
        return 0 ;;
    '') ;;
    *) _ui_error '用法: clashupdate'; return 1 ;;
    esac
    # 文件更新使用 Bash 的数组和锁；非 Bash 解释器只负责加载更新后的命令。
    if _clashctl_in_bash; then
        _update_scripts
    else
        _clashctl_run_in_bash _update_scripts
    fi || return 1
    . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || {
        _ui_error 'clashctl 已更新，但当前 Shell 加载失败，请重开终端'
        return 1
    }
    _ui_ok_out '更新完成，当前 Shell 已加载新版本'
}

_update_scripts() (
    set -o pipefail
    local branch=${CLASHCTL_UPDATE_BRANCH:-master} url target dirty method work='' stage rc install_source
    trap '
        rc=$?
        trap - EXIT
        trap "" INT TERM HUP
        [ -z "$work" ] || [ -f "$work/keep" ] || rm -rf -- "$work"
        operation_lock_release || true
        exit "$rc"
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    operation_lock_acquire || return 1
    [ -f "$CLASHCTL_HOME/.env" ] || { _ui_error '未找到安装配置'; return 1; }
    # 从本次源码加载共用函数，不依赖安装入口。
    install_source=${CLASHCTL_INSTALL_LOCK_LIB:-}
    if [ -n "$install_source" ]; then
        install_source=${install_source%/scripts/lib/operation-lock.sh}
    else
        install_source=$CLASHCTL_HOME
    fi
    # shellcheck source=/dev/null
    . "$install_source/scripts/install-common.sh" || return 1
    method=$(_install_method "$(cd -- "$CLASHCTL_HOME" && pwd -P)") || {
        _ui_error '缺少匹配的安装标记，已停止更新'
        return 1
    }
    work=$(mktemp -d "${CLASHCTL_HOME}.update.XXXXXX") || return 1
    stage="$work/source"
    mkdir "$stage" || return 1
    _ui_step "下载更新：$branch"
    if [ "$method" = git ]; then
        if ! command -v git >/dev/null 2>&1 || [ ! -d "$CLASHCTL_HOME/.git" ] || [ -L "$CLASHCTL_HOME/.git" ]; then
            _ui_error '此安装使用 Git，请先恢复 git 命令或仓库；不会自动切换安装类型'
            return 1
        fi
        dirty=$(git -C "$CLASHCTL_HOME" status --porcelain --untracked-files=no) || return 1
        [ -z "$dirty" ] || { _ui_error '安装目录存在本地代码修改，请提交或暂存后重试'; return 1; }
        url=$(gh_proxy_url 'https://github.com/nelvko/clashctl.git')
        git -C "$CLASHCTL_HOME" -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 \
            fetch --depth 1 -- "$url" "$branch" || return 1
        target=$(git -C "$CLASHCTL_HOME" rev-parse FETCH_HEAD) || return 1
        git -C "$CLASHCTL_HOME" archive "$target" | tar -x -C "$stage" || return 1
    else
        if [ -e "$CLASHCTL_HOME/.git" ] || [ -L "$CLASHCTL_HOME/.git" ]; then
            _ui_error '压缩包安装目录出现 Git 元数据，已停止更新'
            return 1
        fi
        _source_archive "$stage" "$branch" "${GH_PROXY:-}" || return 1
    fi
    [ ! -e "$stage/.git" ] && [ ! -L "$stage/.git" ] || return 1
    _source_validate "$stage" || return 1
    _source_apply_update "$stage" "$method" "${target:-}" "$work"
)
