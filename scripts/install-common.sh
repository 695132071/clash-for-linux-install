#!/usr/bin/env bash
# 安装与更新共用的源码替换与恢复；source 只定义函数。

# 工作树已确认干净；只回退程序文件，保留未跟踪的用户文件。
_update_git_checkout() (
    local target=$1 work=$2 previous previous_ref file dirty failed=false
    local started=false complete=false rc
    local -a added_files=()
    previous=$(git -C "$CLASHCTL_HOME" rev-parse HEAD) || return 1
    previous_ref=$(git -C "$CLASHCTL_HOME" symbolic-ref --quiet HEAD) || previous_ref=''
    git -C "$CLASHCTL_HOME" ls-tree -rz --name-only "$target" >"$work/git-target-files" || return 1
    while IFS= read -r -d '' file; do
        _update_path_safe "$file" || { _ui_error "更新路径无法安全使用：$file"; return 1; }
        if ! git -C "$CLASHCTL_HOME" ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
            if [ -e "$CLASHCTL_HOME/$file" ] || [ -L "$CLASHCTL_HOME/$file" ]; then
                _ui_error "更新会覆盖未跟踪文件，已停止更新：$file"
                return 1
            fi
            added_files+=("$file")
        fi
    done <"$work/git-target-files"
    printf '%s\n%s\n' "$previous" "$previous_ref" >"$work/git-previous" || return 1
    trap '
        rc=$?
        trap - EXIT
        trap "" INT TERM HUP
        if [ "$started" = true ] && [ "$complete" = false ]; then
            # checkout 可能只写了新文件，尚未更新索引；reset 不一定会清理它们。
            for file in "${added_files[@]}"; do
                rm -f -- "$CLASHCTL_HOME/$file" || failed=true
            done
            git -C "$CLASHCTL_HOME" reset --hard -q "$previous" || failed=true
            if [ -n "$previous_ref" ]; then
                git -C "$CLASHCTL_HOME" symbolic-ref HEAD "$previous_ref" || failed=true
            fi
            dirty=$(git -C "$CLASHCTL_HOME" status --porcelain --untracked-files=no) || failed=true
            [ -z "$dirty" ] || failed=true
            [ "$(git -C "$CLASHCTL_HOME" rev-parse HEAD)" = "$previous" ] || failed=true
            if [ "$failed" = true ]; then
                touch "$work/keep"
                _ui_error "更新失败且无法完整恢复原版本，请保留现场检查"
                _ui_detail "恢复信息" "$work/git-previous"
            else
                _ui_error "更新未完成，已恢复原版本"
            fi
            [ "$rc" -ne 0 ] || rc=1
        fi
        operation_lock_release || true
        exit "$rc"
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    started=true
    git -C "$CLASHCTL_HOME" checkout --detach -q "$target" || return 1
    complete=true
)

# 检查整个目标路径，防止通过目录软链接覆盖安装目录以外的文件。
_update_path_safe() {
    local path=$1
    while [ "$path" != . ]; do
        [ ! -L "$CLASHCTL_HOME/$path" ] || return 1
        path=$(dirname -- "$path")
        [ ! -e "$CLASHCTL_HOME/$path" ] || [ -d "$CLASHCTL_HOME/$path" ] || return 1
    done
}

_update_archive() (
    set -o pipefail
    local stage=$1 work=$2 hash file started=false complete=false failed=false rc
    local manifest="$CLASHCTL_HOME/.clashctl-files"
    local -a old_files=() new_files=()
    local -A old_set=() new_set=()
    if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
        _ui_error '源码文件清单缺失，已停止更新'; return 1
    fi
    while read -r hash file; do
        if [[ ! "$hash" =~ ^[0-9a-f]{64}$ ]] || [[ "$file" != ./* ]] ||
            ! _source_path_allowed "$file" || ! _update_path_safe "$file" || [ ! -f "$CLASHCTL_HOME/$file" ]; then
            _ui_error '源码文件清单或安装路径无效'; return 1
        fi
        old_files+=("$file")
        old_set[$file]=1
    done <"$manifest"
    [ "${#old_files[@]}" -gt 0 ] || return 1
    (cd -- "$CLASHCTL_HOME" && sha256sum --status -c .clashctl-files) || {
        _ui_error '安装目录存在本地代码修改或缺失文件，请恢复后重试'
        return 1
    }
    _source_manifest "$stage" >"$stage/.clashctl-files" || return 1
    while read -r hash file; do
        _update_path_safe "$file" || { _ui_error "更新路径无法安全使用：$file"; return 1; }
        if [ -e "$CLASHCTL_HOME/$file" ]; then
            if [ ! -f "$CLASHCTL_HOME/$file" ] || [ "${old_set[$file]:-}" != 1 ]; then
                _ui_error "更新会覆盖非托管文件：$file"
                return 1
            fi
        fi
        new_files+=("$file")
        new_set[$file]=1
    done <"$stage/.clashctl-files"
    tar -cf "$work/previous.tar" -C "$CLASHCTL_HOME" -- "${old_files[@]}" .clashctl-files || return 1
    # 更新失败只恢复程序文件；订阅、组件和运行数据始终不参与替换。
    trap '
        rc=$?
        trap - EXIT
        trap "" INT TERM HUP
        if [ "$started" = true ] && [ "$complete" = false ]; then
            for file in "${new_files[@]}"; do
                [ "${old_set[$file]:-}" = 1 ] || rm -f -- "$CLASHCTL_HOME/$file" || failed=true
            done
            tar -xf "$work/previous.tar" -C "$CLASHCTL_HOME" || failed=true
            if [ "$failed" = true ]; then
                touch "$work/keep"
                _ui_error "恢复源码失败，备份保留在 $work/previous.tar"
            else
                _ui_error "更新未完成，原程序文件已恢复"
            fi
            [ "$rc" -ne 0 ] || rc=1
        fi
        operation_lock_release || true
        exit "$rc"
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    started=true
    tar -cf - -C "$stage" -- "${new_files[@]}" .clashctl-files |
        tar -xf - -C "$CLASHCTL_HOME" || return 1
    for file in "${old_files[@]}"; do
        [ "${new_set[$file]:-}" = 1 ] || rm -f -- "$CLASHCTL_HOME/$file" || return 1
    done
    complete=true
)
