#!/usr/bin/env bash
# 真实 Bash/Zsh/Fish 加载器与 Git/压缩包更新；只有下载来源替换成本地 fixture。
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v zsh >/dev/null || fail 'zsh is required'
export REAL_GIT SOURCE_REPO="$WORK_DIR/source" SOURCE_ARCHIVE="$WORK_DIR/source.tar.gz"
REAL_GIT=$(command -v git)
mkdir -p "$SOURCE_REPO" "$WORK_DIR/bin"
cp -a "$REPO_DIR/scripts" "$SOURCE_REPO/"
cp "$REPO_DIR/"{install.sh,uninstall.sh,.env.example,.gitignore} "$SOURCE_REPO/"
# 安装入口即使有效但不能被执行，脚本更新也应只加载共用库。
printf 'printf "unexpected installer load\\n" >&2; exit 95\n' >"$SOURCE_REPO/install.sh"
printf 'CLASHCTL_TEST_VERSION=old\n' >"$SOURCE_REPO/scripts/cmd/version.sh"
"$REAL_GIT" -C "$SOURCE_REPO" init -q -b master
"$REAL_GIT" -C "$SOURCE_REPO" config user.email test@example.invalid
"$REAL_GIT" -C "$SOURCE_REPO" config user.name test
"$REAL_GIT" -C "$SOURCE_REPO" add .
"$REAL_GIT" -C "$SOURCE_REPO" commit -qm initial
INITIAL_HEAD=$("$REAL_GIT" -C "$SOURCE_REPO" rev-parse HEAD)
. "$REPO_DIR/install.sh"
for shell in bash zsh; do
    for method in git archive; do
        home_dir="$WORK_DIR/$shell-$method"
        if [ "$method" = git ]; then
            "$REAL_GIT" clone -q "$SOURCE_REPO" "$home_dir"
        else
            mkdir "$home_dir"
            "$REAL_GIT" -C "$SOURCE_REPO" archive HEAD | tar -x -C "$home_dir"
            _source_manifest "$home_dir" >"$home_dir/.clashctl-files"
        fi
        printf '%s\n%s\n' "$home_dir" "$method" >"$home_dir/.clashctl-install"
        printf 'CLASHCTL_KERNEL=mihomo\nCLASHCTL_UPDATE_BRANCH=master\nGH_PROXY=\n' >"$home_dir/.env"
    done
done
printf 'CLASHCTL_TEST_VERSION=new\n' >"$SOURCE_REPO/scripts/cmd/version.sh"
printf 'clashfuture() { printf "new-command\\n"; }\n' >"$SOURCE_REPO/scripts/cmd/future.sh"
printf 'new_helper=true\n' >"$SOURCE_REPO/scripts/new-helper.sh"
# 目标版本移动私有模块；旧更新器只能依赖稳定入口，不能继续读取旧路径。
mv "$SOURCE_REPO/scripts/install-common.sh" "$SOURCE_REPO/scripts/source-common.sh"
mv "$SOURCE_REPO/scripts/lib/operation-lock.sh" "$SOURCE_REPO/scripts/lib/lifecycle-lock.sh"
while IFS= read -r -d '' source_file; do
    sed -i -e 's/install-common\.sh/source-common.sh/g' \
        -e 's/operation-lock\.sh/lifecycle-lock.sh/g' "$source_file"
done < <(find "$SOURCE_REPO/scripts" -type f -name '*.sh' -print0)
"$REAL_GIT" -C "$SOURCE_REPO" add .
"$REAL_GIT" -C "$SOURCE_REPO" commit -qm update
"$REAL_GIT" -C "$SOURCE_REPO" archive --prefix=source/ HEAD | gzip >"$SOURCE_ARCHIVE"
cat >"$WORK_DIR/bin/git" <<'STUB'
#!/usr/bin/env bash
if [ -n "${CHECKOUT_FAILURE:-}" ] && [ "${1:-}" = -C ]; then
    home_dir=$2
    if [ "${3:-}" = checkout ]; then
        printf 'CLASHCTL_TEST_VERSION=partial\n' >"$home_dir/scripts/cmd/version.sh"
        printf 'partial helper\n' >"$home_dir/scripts/new-helper.sh"
        case "$CHECKOUT_FAILURE" in
        detached) "$REAL_GIT" "$@" || exit 1 ;;
        signal) kill -TERM "$PPID" ;;
        esac
        exit 1
    fi
    if [ "$CHECKOUT_FAILURE" = rollback ] && [ "${3:-}" = reset ]; then exit 1; fi
fi
args=()
for arg in "$@"; do
    case "$arg" in *github.com/nelvko/clashctl.git) arg=$SOURCE_REPO ;; esac
    args+=("$arg")
done
exec "$REAL_GIT" "${args[@]}"
STUB
cat >"$WORK_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
    case "$1" in -o) destination=$2; shift ;; esac
    shift
done
cp "$SOURCE_ARCHIVE" "$destination"
STUB
chmod +x "$WORK_DIR/bin/"*
# 目标缺少交接入口或它自己的内部文件时，旧版必须在源码替换前停止。
TARGET_HEAD=$("$REAL_GIT" -C "$SOURCE_REPO" rev-parse HEAD)
for invalid in entry private-file; do
    if [ "$invalid" = entry ]; then
        sed -i 's/^_update_apply_source()/_removed_apply_source()/' "$SOURCE_REPO/scripts/cmd/update.sh"
    else
        rm "$SOURCE_REPO/uninstall.sh"
    fi
    "$REAL_GIT" -C "$SOURCE_REPO" add -A
    "$REAL_GIT" -C "$SOURCE_REPO" commit -qm "invalid-$invalid"
    "$REAL_GIT" -C "$SOURCE_REPO" archive --prefix=source/ HEAD | gzip >"$SOURCE_ARCHIVE"
    PATH="$WORK_DIR/bin:$PATH" CLASHCTL_HOME="$WORK_DIR/bash-archive" bash -c '
        . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || exit 1
        clashctl update
    ' >"$WORK_DIR/output" 2>&1 && fail "invalid target accepted: $invalid"
    grep -q '源码不兼容' "$WORK_DIR/output" || { cat "$WORK_DIR/output"; fail "missing target diagnosis: $invalid"; }
    (cd "$WORK_DIR/bash-archive" && sha256sum --status -c .clashctl-files) ||
        fail "invalid target changed installed source: $invalid"
    [ -z "$(find "$WORK_DIR" -maxdepth 1 -name 'bash-archive.update.*' -print -quit)" ] ||
        fail "invalid target retained temporary files: $invalid"
    "$REAL_GIT" -C "$SOURCE_REPO" reset --hard -q "$TARGET_HEAD"
done
"$REAL_GIT" -C "$SOURCE_REPO" archive --prefix=source/ HEAD | gzip >"$SOURCE_ARCHIVE"
for shell in bash zsh; do
    shell_args=(-c)
    [ "$shell" != zsh ] || shell_args=(-f -c)
    for method in git archive; do
        # shellcheck disable=SC2016  # 变量由被测 Shell 展开。
        PATH="$WORK_DIR/bin:$PATH" CLASHCTL_HOME="$WORK_DIR/$shell-$method" "$shell" "${shell_args[@]}" '
            . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || exit 1
            [ "$CLASHCTL_TEST_VERSION" = old ] || exit 1
            clashctl update || exit 1
            [ "$CLASHCTL_TEST_VERSION" = new ] || exit 1
            [ ! -e "$CLASHCTL_HOME/scripts/install-common.sh" ] || exit 1
            [ ! -e "$CLASHCTL_HOME/scripts/lib/operation-lock.sh" ] || exit 1
            # 改名后的目标入口也能再次更新，不能依赖当前 Shell 残留的旧函数。
            bash -c '\''. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashctl update'\'' || exit 1
        ' >"$WORK_DIR/output" 2>&1 || { cat "$WORK_DIR/output"; fail "$shell $method update failed"; }
    done
done
# checkout 可在索引、HEAD 尚未切换时失败，也可在切换后失败；两者都必须恢复。
for shell in bash zsh; do
    shell_args=(-c)
    [ "$shell" != zsh ] || shell_args=(-f -c)
    for failure in partial detached signal collision rollback; do
        home_dir="$WORK_DIR/$shell-failure-$failure"
        "$REAL_GIT" clone -q "$SOURCE_REPO" "$home_dir"
        "$REAL_GIT" -C "$home_dir" reset --hard -q "$INITIAL_HEAD"
        printf '%s\ngit\n' "$home_dir" >"$home_dir/.clashctl-install"
        printf 'CLASHCTL_KERNEL=mihomo\nCLASHCTL_UPDATE_BRANCH=master\nGH_PROXY=\n' >"$home_dir/.env"
        mkdir "$home_dir/data"
        printf 'user runtime\n' >"$home_dir/data/private"
        printf 'untracked user file\n' >"$home_dir/user-notes"
        if [ "$failure" = collision ]; then printf 'user helper\n' >"$home_dir/scripts/new-helper.sh"; fi
        PATH="$WORK_DIR/bin:$PATH" CHECKOUT_FAILURE="$failure" CLASHCTL_HOME="$home_dir" \
            "$shell" "${shell_args[@]}" '
                . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || exit 1
                clashctl update
            ' >"$WORK_DIR/output" 2>&1 && fail "$shell accepted failed checkout: $failure"
        [ "$(cat "$home_dir/user-notes")" = 'untracked user file' ] || fail 'rollback lost untracked user file'
        [ "$(cat "$home_dir/data/private")" = 'user runtime' ] || fail 'rollback lost runtime data'
        grep -qx 'CLASHCTL_KERNEL=mihomo' "$home_dir/.env" || fail 'rollback modified config'
        if [ "$failure" = rollback ]; then
            grep -q '无法完整恢复原版本' "$WORK_DIR/output" || { cat "$WORK_DIR/output"; fail 'rollback failure was hidden'; }
            recovery=$(find "$WORK_DIR" -maxdepth 1 -name "$shell-failure-$failure.update.*" -print -quit)
            [ -n "$recovery" ] && [ -f "$recovery/keep" ] || fail 'rollback failure removed recovery information'
            [ "$(head -n 1 "$recovery/git-previous")" = "$INITIAL_HEAD" ] || fail 'rollback lost previous commit'
            continue
        fi
        [ "$("$REAL_GIT" -C "$home_dir" rev-parse HEAD)" = "$INITIAL_HEAD" ] || fail "$shell rollback changed HEAD: $failure"
        [ "$("$REAL_GIT" -C "$home_dir" symbolic-ref HEAD)" = refs/heads/master ] || fail "$shell rollback lost branch: $failure"
        [ -z "$("$REAL_GIT" -C "$home_dir" status --porcelain --untracked-files=no)" ] || fail "$shell rollback left tracked changes: $failure"
        if [ "$failure" = collision ]; then
            [ "$(cat "$home_dir/scripts/new-helper.sh")" = 'user helper' ] || fail 'update overwrote untracked collision'
            grep -q '更新会覆盖未跟踪文件' "$WORK_DIR/output" || fail 'untracked collision was not diagnosed'
        else
            [ ! -e "$home_dir/scripts/new-helper.sh" ] || fail "$shell rollback left partial new file: $failure"
            grep -q '已恢复原版本' "$WORK_DIR/output" || { cat "$WORK_DIR/output"; fail "$shell rollback was not reported: $failure"; }
            # 恢复后应可重试成功，不能再被“存在本地代码修改”阻塞。
            PATH="$WORK_DIR/bin:$PATH" CLASHCTL_HOME="$home_dir" "$shell" "${shell_args[@]}" '
                . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || exit 1
                clashctl update || exit 1
                [ "$CLASHCTL_TEST_VERSION" = new ]
            ' >"$WORK_DIR/output" 2>&1 || { cat "$WORK_DIR/output"; fail "$shell could not retry after $failure"; }
        fi
        [ -z "$(find "$WORK_DIR" -maxdepth 1 -name "$shell-failure-$failure.update.*" -print -quit)" ] || fail 'recovered update left temporary files'
    done
done
printf 'update-shells: ok\n'
