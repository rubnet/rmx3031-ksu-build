# KernelSU-Next LKM for RMX3031 (GitHub Actions 云编译)

用 GitHub Actions 的免费 Linux 编译机，为 RMX3031（MT6893，kernel 4.14.186+）编译 KernelSU-Next 内核模块，绕开本地没有 Linux 环境的限制。

## 产物

编译成功后在 Actions 页面下载 artifact `kernelsu-rmx3031`，包含：
- `kernelsu_rmx3031.ko` — 已自签名的 KernelSU-Next 内核模块
- `ghost_rmx3031.crt.der` — 对应的 DER 证书（给 stage1 add_key 用）
- `signing_cert.pem` — PEM 证书
- `ksu_build.log` — 编译日志

## 使用方法

### 1. 建仓库并推送
```bash
# 在 GitHub 新建一个空仓库（比如叫 rmx3031-ksu-build），然后：
cd 这个目录
git init
git add .
git commit -m "KernelSU-Next LKM build for RMX3031"
git remote add origin https://github.com/<你的用户名>/rmx3031-ksu-build.git
git push -u origin main
```

### 2. 触发编译
push 后 Actions 自动开始（也可在 Actions 页面手动 Run workflow）。
等待约 10-30 分钟完成。

### 3. 下载产物
Actions 页面 → 本次运行 → Artifacts → `kernelsu-rmx3031` 下载 zip。

## 编译流程（workflow 自动做的）

1. 装工具链（aarch64-linux-gnu-gcc、bc、flex、bison、libssl-dev…）
2. clone 内核源码（nishant6342 R 分支，4.14.300）→ 改 SUBLEVEL=186 / EXTRAVERSION=+ 对齐设备 vermagic `4.14.186+`
3. clone KernelSU-Next（legacy 分支，non-GKI 4.14，tracepoint hook 不依赖 kprobe）
4. 用仓库里的 `device.config`（从真机 /proc/config.gz 导出）做 olddefconfig + modules_prepare
5. 打 4.14 compat shim
6. `make M=KernelSU-Next/kernel CONFIG_KSU=m ... modules`
7. 生成自签 RSA-2048 密钥 + SHA512 签名
8. 上传 artifacts

## 下载后如何加载（设备端）

把 `.ko` 和证书推到设备，用 stage1 的签名闸门绕过原语加载：
```bash
adb push kernelsu_rmx3031.ko /data/local/tmp/
adb push ghost_rmx3031.crt.der /data/local/tmp/
adb shell "cd /data/local/tmp && ./stage1 --aw-fops --slide 0x... --permissive \
  --ksu-probe /data/local/tmp/ghost_rmx3031.crt.der \
  --ksu-mod-r /data/local/tmp/kernelsu_rmx3031.ko"
```
（stage1 的 `--ksu-probe` 会换 builtin_trusted_keys 信任环 + insmod）

## 注意

- kernel 源码 R 分支是 4.14.300，改 SUBLEVEL 到 186 只是 vermagic 对齐；4.14 各小版本 struct module 布局一致（账本实证），但 syscall ABI 等差异可能需调试。
- 若编译失败，去 Actions 页面看日志；常见原因是 compat shim 缺 API，按报错补。
- LKM 是内存态（tethered），重启失效，需重跑加载流程。
