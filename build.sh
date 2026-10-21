#!/usr/bin/env bash
# DeepSeek 悬浮窗 —— 一键编译打包（仅需 Xcode CommandLineTools，不需要完整 Xcode）
#
#   ./build.sh            编译并生成 build/DeepSeekFloat.app
#   ./build.sh run        编译后从 build/ 启动（开发用）
#   ./build.sh install    编译 + 安装到 /Applications + 启动（正式用法）
#   ./build.sh uninstall  卸载；加 --purge 连凭据与偏好一起删
#   ./build.sh status     查看安装 / 运行 / 开机自启 / 凭据状态
#   ./build.sh package    生成可分发的 zip
#   ./build.sh icon       生成 AppIcon.icns
#   ./build.sh test       编译并跑全部自检断言
#   ./build.sh clean      清理 build 目录
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXEC_NAME="DeepSeekFloat"
APP="$ROOT/build/$EXEC_NAME.app"
SDK_TARGET="arm64-apple-macos14.0"

# 安装目标（本机自用，只装这一份）
INSTALL_DIR="/Applications"
INSTALLED_APP="$INSTALL_DIR/$EXEC_NAME.app"
BUNDLE_ID="com.dsh.deepseek-float"
SUPPORT_DIR="$HOME/Library/Application Support/DeepSeekFloat"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

log() { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# 安装/卸载前必须先退掉旧实例：覆盖正在运行的 .app 会让进程继续握着已被替换的二进制，
# 后面看到的行为全是旧版本的，排查起来极其误导。
quit_running() {
  if pgrep -x "$EXEC_NAME" >/dev/null 2>&1; then
    log "退出正在运行的实例"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    sleep 1
    pkill -x "$EXEC_NAME" >/dev/null 2>&1 || true
    sleep 1
  fi
}

cmd_clean() { rm -rf "$ROOT/build"; log "已清理 build/"; }

cmd_icon() {
  log "生成应用图标 AppIcon.icns"
  local iconset="$ROOT/build/AppIcon.iconset"
  rm -rf "$iconset"; mkdir -p "$iconset" "$ROOT/Resources"
  local tmpbin="$ROOT/build/icon-gen"
  mkdir -p "$ROOT/build" "$ROOT/build/ModuleCache"
  swiftc -swift-version 5 -O \
    -module-cache-path "$ROOT/build/ModuleCache" \
    -o "$tmpbin" "$ROOT/Tools/IconGen.swift" -framework AppKit \
    || die "图标生成器编译失败"
  "$tmpbin" "$iconset" || die "图标绘制失败"
  iconutil -c icns "$iconset" -o "$ROOT/Resources/AppIcon.icns" || die "iconutil 失败"
  log "已生成 Resources/AppIcon.icns"
}

cmd_build() {
  command -v swiftc >/dev/null 2>&1 || die "未找到 swiftc，请先安装 Xcode CommandLineTools：xcode-select --install"

  log "清理旧产物"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

  local files
  files=$(find "$ROOT/Sources" -name '*.swift' | sort)
  [ -n "$files" ] || die "Sources/ 下没有 Swift 文件"

  log "编译 Swift（$(echo "$files" | wc -l | tr -d ' ') 个文件）"
  # shellcheck disable=SC2086
  swiftc \
    -swift-version 5 \
    -parse-as-library \
    -O \
    -target "$SDK_TARGET" \
    -module-cache-path "$ROOT/build/ModuleCache" \
    -o "$APP/Contents/MacOS/$EXEC_NAME" \
    $files \
    -framework AppKit \
    -framework SwiftUI \
    -framework Foundation \
    -framework UserNotifications \
    -framework Security \
    -framework ServiceManagement \
    2>&1 | sed 's/^/  /'
  [ -x "$APP/Contents/MacOS/$EXEC_NAME" ] || die "编译失败"

  cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
  if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
  fi

  log "ad-hoc 签名"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || log "签名跳过（不影响本机运行）"

  local size
  size=$(du -sh "$APP" | cut -f1)
  log "完成 → $APP  ($size)"
}

cmd_install() {
  cmd_build
  quit_running

  # 重装前先记住「开机自启」是否开着。
  # ad-hoc 签名每次编译 cdhash 都会变，等于换了一个代码身份，
  # SMAppService 原先的注册会失效 —— 不自动恢复的话，用户每次更新都要手动再开一次。
  local had_login_item=false
  if [ -x "$INSTALLED_APP/Contents/MacOS/$EXEC_NAME" ] \
     && "$INSTALLED_APP/Contents/MacOS/$EXEC_NAME" --login-item status >/dev/null 2>&1; then
    had_login_item=true
  fi

  log "安装到 $INSTALL_DIR"
  rm -rf "$INSTALLED_APP"
  # ditto 会连代码签名与扩展属性一起搬，比 cp -R 可靠
  ditto "$APP" "$INSTALLED_APP"
  xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true

  # 主动登记 LaunchServices。不登记会有两个后果：
  #   1) Spotlight / Launchpad 收录延迟很久
  #   2) 开机自启（SMAppService）报 notFound —— 它要求系统认得这个 bundle
  [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || true

  log "校验产物"
  codesign -dv "$INSTALLED_APP" 2>&1 | grep -E '^Identifier|^Signature|^Format' | sed 's/^/  /' || true
  if codesign --verify --deep --strict "$INSTALLED_APP" >/dev/null 2>&1; then
    log "签名校验通过"
  else
    warn "签名校验有告警（ad-hoc 签名属正常，不影响本机运行）"
  fi

  if [ "$had_login_item" = true ]; then
    if "$INSTALLED_APP/Contents/MacOS/$EXEC_NAME" --login-item enable >/dev/null 2>&1; then
      log "已恢复开机自启注册（ad-hoc 重装会使其失效）"
    else
      warn "开机自启恢复失败；请在菜单栏里重新开启一次"
    fi
  fi

  log "启动"
  open "$INSTALLED_APP"
  sleep 2
  if pgrep -x "$EXEC_NAME" >/dev/null 2>&1; then
    log "已安装并运行 → $INSTALLED_APP"
  else
    warn "已安装但进程没起来；打开「控制台」搜 $EXEC_NAME 看崩溃原因"
  fi
}

cmd_uninstall() {
  local purge="${1:-}"
  quit_running

  # 必须先注销开机自启再删 .app：删完 SMAppService 找不到 bundle 就注销不掉，
  # 会留下一个每次开机都失败的登录项
  log "注销开机自启"
  local candidate
  for candidate in "$INSTALLED_APP/Contents/MacOS/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"; do
    if [ -x "$candidate" ]; then
      "$candidate" --login-item disable 2>&1 | sed 's/^/  /' || true
      break
    fi
  done

  log "删除 $INSTALLED_APP"
  rm -rf "$INSTALLED_APP"
  [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$INSTALLED_APP" >/dev/null 2>&1 || true

  if [ "$purge" = "--purge" ]; then
    log "清除凭据与偏好"
    rm -rf "$SUPPORT_DIR"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  else
    log "已保留凭据与偏好；要一并删除请用 ./build.sh uninstall --purge"
  fi
  log "已卸载"
}

cmd_status() {
  echo "── DeepSeek 悬浮窗 状态 ──"
  if [ -d "$INSTALLED_APP" ]; then
    printf "  安装位置 : %s\n" "$INSTALLED_APP"
    printf "  版本     : %s\n" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || echo '?')"
    printf "  签名     : %s\n" "$(codesign -dv "$INSTALLED_APP" 2>&1 | grep -E '^Signature' | cut -d= -f2 || echo '?')"
  else
    printf "  安装位置 : 未安装（执行 ./build.sh install）\n"
  fi

  if pgrep -x "$EXEC_NAME" >/dev/null 2>&1; then
    printf "  运行状态 : 运行中 (pid %s)\n" "$(pgrep -x "$EXEC_NAME" | head -1)"
  else
    printf "  运行状态 : 未运行\n"
  fi

  local bin="$INSTALLED_APP/Contents/MacOS/$EXEC_NAME"
  [ -x "$bin" ] || bin="$APP/Contents/MacOS/$EXEC_NAME"
  if [ -x "$bin" ]; then
    # 注意别写成 $(... || echo '?')：--login-item status 在「未启用」时返回退出码 1，
    # 配合 pipefail 会让整个替换失败，于是状态后面多出一个莫名其妙的问号
    local login_state notify_state
    login_state=$("$bin" --login-item status 2>/dev/null | sed 's/^开机自启：//' | head -1) || true
    notify_state=$("$bin" --notify-status 2>/dev/null | sed 's/^通知权限：//' | head -1) || true
    printf "  开机自启 : %s\n" "${login_state:-未知}"
    printf "  通知权限 : %s\n" "${notify_state:-未知}"
  fi

  if [ -f "$SUPPORT_DIR/credentials.json" ]; then
    printf "  凭据     : 已保存（权限 %s）\n" "$(stat -f '%Sp' "$SUPPORT_DIR/credentials.json")"
  else
    printf "  凭据     : 未保存，首次启动请在设置页填 API Key\n"
  fi
}

case "${1:-build}" in
  build)   cmd_build ;;
  run)     cmd_build; log "启动"; open "$APP" ;;
  install) cmd_install ;;
  uninstall) cmd_uninstall "${2:-}" ;;
  status)  cmd_status ;;
  package)
    cmd_build
    log "打包 zip"
    ( cd "$ROOT/build" && ditto -c -k --sequesterRsrc --keepParent "$EXEC_NAME.app" "$EXEC_NAME.zip" )
    log "完成 → $ROOT/build/$EXEC_NAME.zip"
    ;;
  icon)    cmd_icon ;;
  test)
    cmd_build
    log "解析器夹具测试"
    "$APP/Contents/MacOS/$EXEC_NAME" --parsetest
    ;;
  clean)   cmd_clean ;;
  *)       die "未知命令：$1（可用：build / run / install / uninstall / status / package / icon / test / clean）" ;;
esac
