#!/bin/sh
# 修复 host 端 aclocal 宏被 gnulib 覆盖的问题
#
# 症状（编译 dcwapd 或任何使用 AM_CONDITIONAL 的 autotools 包时）：
#   configure.ac:30: error: possibly undefined macro: AM_CONDITIONAL
#   autoreconf: error: .../bin/autoconf failed with exit status: 1
#   configure: error: cannot find required auxiliary files: ar-lib
#
# 根因：
#   OpenWrt 通过 ACLOCAL_INCLUDE 传入 -I $(STAGING_DIR_HOST)/share/aclocal
#   （include/package.mk:203），而 aclocal 对同名 *.m4 只采用第一个命中的文件。
#   host 编译 gettext-full/gnulib 时会把 gnulib 的 cond.m4（只定义 gl_COND）
#   安装到 share/aclocal/，恰好与 automake 1.18 的 cond.m4（定义 AM_CONDITIONAL）
#   同名，于是 AM_CONDITIONAL 宏消失。
#
# 处理：把 gnulib 的那份改名（去掉 .m4 后缀，aclocal 就不会再扫描它），
#       让 aclocal 回退到 automake 自带的 share/aclocal-1.18/cond.m4。
#
# 幂等：可重复执行。每次 make dirclean / 重新构建 gettext host 后若复发，再跑一次。

set -e

STAGING_HOST="${1:-$(cd "$(dirname "$0")/../.." && pwd)/lede/staging_dir/host}"

TARGET="$STAGING_HOST/share/aclocal/cond.m4"
BACKUP="$TARGET.gnulib.bak"

if [ ! -f "$TARGET" ]; then
    echo "跳过：$TARGET 不存在"
    exit 0
fi

# 只处理 gnulib 版本（其内容定义 gl_COND 而非 AM_CONDITIONAL）
if grep -q "AM_CONDITIONAL" "$TARGET"; then
    echo "跳过：$TARGET 已是 automake 版本（含 AM_CONDITIONAL）"
    exit 0
fi

if [ -f "$BACKUP" ]; then
    rm -f "$TARGET"
else
    mv "$TARGET" "$BACKUP"
fi

echo "已隔离 gnulib 的 cond.m4 → $BACKUP"
echo "验证："
grep -l "AC_DEFUN(\[AM_CONDITIONAL" "$STAGING_HOST"/share/aclocal-1.18/cond.m4 >/dev/null 2>&1 \
    && echo "  automake 的 cond.m4 定义 AM_CONDITIONAL ✔" \
    || echo "  警告：未在 share/aclocal-1.18/cond.m4 找到 AM_CONDITIONAL 定义"
