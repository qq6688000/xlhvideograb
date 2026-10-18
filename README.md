# XLH VideoGrab — 悬浮抓取网页视频链接

> iOS 15+ / **Dopamine 无根越狱（/var/jb）** 专用插件
> 在 Safari 或任意浏览器里点一下悬浮球，就能列出当前网页里所有视频/音频真实地址，
> 支持一键下载（含 m3u8 解析 + 分片合并）。

---

## 一、它做了什么

| 能力 | 说明 |
|---|---|
| 悬浮球 | 网页出现时自动浮在屏幕上，可拖动、自动吸边、位置按 App 记忆 |
| 抓取 | 注入页面脚本，拦截 `fetch` / `XMLHttpRequest` / `<video src>` / `<source>` / `loadstart` / `PerformanceObserver` / `og:video` / HTML 源码正则 |
| 识别 | 自动分类：HLS(m3u8)、DASH(mpd)、直链(mp4/webm/mov…)、音频、ts 分片 |
| 下载 | 直链走 `NSURLSession`；m3u8 自动选最高码率变体、按顺序拉分片、拼成 `.ts` |
| 保存 | 下载完成后弹系统分享面板 → “存储到文件” / 存到相册 / 发到其他 App |
| 去重 | 同一个 URL 只保留一条，记录命中次数 |

**抓不到的情况（技术限制，不是 bug）：**

- `blob:` 地址（MSE / 部分网站的自定义播放器，视频数据在 JS 内存里，没有真实 URL）
- DRM 加密流（Widevine / FairPlay）
- AES-128 加密的 HLS：只能保存 `.m3u8` 播放列表，不会合并

---

## 二、编译（不用 Mac）

设备上没有 theos/clang，所以用 **GitHub Actions** 云编译：

1. 新建一个 GitHub 仓库（Private 也行），把本目录**所有文件**推到仓库根目录；
2. 仓库 → Actions → `Build XLHVideoGrab` → `Run workflow`；
3. 跑完在本次运行页面底部下载 artifact `XLHVideoGrab-deb`，里面就是
   `com.xiaolihai.videograb_1.0.0_iphoneos-arm64.deb`。

本地有 macOS + Theos 的话也可以直接：

```bash
export THEOS=~/theos
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

> 若链接阶段报找不到 `libsubstrate`，把 `Makefile` 里的
> `XLHVideoGrab_LIBRARIES := substrate` 这一行删掉再编译即可
> （Logos 生成的钩子靠 `-undefined dynamic_lookup` 在运行时由 ElleKit 解析）。

---

## 三、安装

把 deb 传到手机，用 **Sileo / Zebra** 打开安装（Dopamine 环境），然后：

```
注销一次（或 killall -9 SpringBoard）
```

确认文件落位：

```sh
ls /var/jb/usr/lib/TweakInject/ | grep -i xlh
# XLHVideoGrab.dylib
# XLHVideoGrab.plist
```

---

## 四、使用

1. 打开 Safari（或其他已注入的浏览器），随便进一个视频网页；
2. 右侧会出现蓝色圆形 **「抓」** 按钮；
3. 点它 → 面板列出抓到的一切，点某一条 → **下载 / 复制链接 / 用 Safari 打开**；
4. 下载完成自动弹分享面板，选择“存储到文件”即可长期保存。

小技巧：

- **拖动**悬浮球到任意位置，松手自动贴边，每个 App 单独记忆；
- **长按**悬浮球：清空列表 / 本次收起悬浮球；
- 面板右上 **「扫描」**：对当前页面做一次深度扫描（DOM + HTML 源码），
  有些地址是懒加载的，播一下视频再点扫描更容易抓到。

---

## 五、命令与配置

```sh
xlgrab status        # 查看状态
xlgrab on / off      # 开关（对新启动的 App 生效）
xlgrab apps          # 查看已注入的 App 列表
xlgrab clean         # 清理临时下载
```

配置目录：`/var/mobile/Library/Preferences/xlhgrab/`
（纯文本文件，改完立刻生效，无需重启）

| 文件 | 作用 |
|---|---|
| `enabled` | `1` / `0` 总开关 |
| `always_show` | `1` 时页面还没加载完也显示悬浮球 |

下载临时目录：`/var/mobile/Documents/XLHVideoGrab/`
（沙盒内临时目录，分享后面板里的文件可以删掉）

### 增加注入的 App

插件默认只在浏览器类 App 里注入（见 `XLHVideoGrab.plist` 的 `Filter.Bundles`）。
想在别的 App 的内置网页里使用，把它的 Bundle ID 加进去：

```sh
# 编辑（Filza 或 vim）
/var/jb/usr/lib/TweakInject/XLHVideoGrab.plist
# 加到 Bundles 数组里，然后
killall -9 SpringBoard
```

想让**所有** App 都生效：把 `Filter` 整个字典删掉（留一个空的 `{}` 文件），
注入范围变成全部进程（内存占用会略微增加）。

---

## 六、代码结构

```
Tweak.xm            Logos 钩子（WKWebView 创建 / 上屏）
VGManager.m         注入、消息汇总、去重、悬浮窗宿主管理
VGScript.mm         注入页面的 JS（C++ raw string，改脚本不用转义）
VGOverlay.m         悬浮球 + 面板 + HUD + 分享
VGDownloader.m      直链下载 / m3u8 解析合并
VGCommon.m          数据模型 + /var/jb 路径 + 文本配置
XLHVideoGrab.plist  注入范围过滤表
layout/usr/bin/xlgrab  命令行配置工具
```

### 关键实现点

- **注入时机**：hook `-[WKWebView initWithFrame:configuration:]`，在 `%orig`
  **之前**把 `WKUserScript` 和 `scriptMessageHandler` 塞进 `configuration`，
  这样页面一开始就能挂上钩子（对 CSP 免疫）。Safari、SFSafariViewController、
  第三方浏览器的 WKWebView 全部覆盖。
- **跨进程问题**：WebKit 的网页内容在独立进程里跑，所以不能用
  `NSURLProtocol` 抓视频；JS 在页面进程里跑，通过 `webkit.messageHandlers`
  把结果送回 App 进程。
- **窗口穿透**：悬浮窗是独立 `UIWindow`（level = Alert+120），根视图
  `hitTest` 在空白区域返回 `nil`，触摸事件原样传给下面的 App，不挡操作。

---

## 七、卸载

Sileo 里卸载即可。残留清理：

```sh
rm -rf /var/mobile/Library/Preferences/xlhgrab
rm -rf /var/mobile/Documents/XLHVideoGrab
```

---

## 八、免责声明

仅供个人学习与自用（抓取自己有权限访问的公开内容）。请遵守目标网站的服务条款与
当地法律，不要用于批量抓取或二次分发受版权保护的内容。
