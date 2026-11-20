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

## 编译失败排查记录 (2026-11-20 第一轮)

第一轮报错及修复：
1. `aarch64-linux-android-gcc: No such file` — 设备 config 里 `CONFIG_CROSS_COMPILE="aarch64-linux-android-"` 是厂商工具链，Actions 没有。已 sed 改成 `aarch64-linux-gnu-`，且所有 make 命令显式带 `CROSS_COMPILE=aarch64-linux-gnu-`。
2. `kernel source is dirty` — clone 后改了 Makefile。已在 prepare 前加 `make mrproper`。
3. **决定性**: `Kbuild:221 No hooks were defined` — KernelSU-Next 必须有 hook 模式。设备无 CONFIG_KPROBES，故选 `CONFIG_KSU_SYSCALL_TABLE_HOOK=y`（模块自带 patch_memory + symbol_resolver，靠 kallsyms_lookup_name 找表，4.14 仍导出该符号）。

### ⚠️ 已知运行期风险
Kconfig 明确写 `KSU_SYSCALL_TABLE_HOOK` 要求 kernel >= 4.17（pt_regs syscall ABI），
而 RMX3031 是 **4.14（C 参数 syscall ABI）**。此模式**能编译出 .ko**，但加载后 syscall hook
可能 ABI 不匹配而崩溃（账本 ZT9 记录过同类问题）。

- **当前 workflow 用 SYSCALL_TABLE_HOOK 优先拿到可编译产物**用于验证加载链路。
- 若加载后崩溃，正确解法是 `KSU_MANUAL_HOOK`：需向内核源码插 hook 点
  （kernel/reboot.c 的 ksu_handle_sys_reboot 等，见账本 ZT13 的 4 处 C 签名钩子），工作量大。
- 另一个思路：把 4.14 的 syscall ABI 适配加进 syscall_table_hook.c（把 pt_regs 参数
  转成 C 参数调用），账本 ZT9 有现成分析。

## 编译失败排查记录 (第二轮)

- `asm/errno.h` / `linux/version.h` Not found：根因是之前用 `O=build` 分离目录，生成的 asm-generic
  符号链接/version.h 落在 build/，模块编译 include 路径找不到。改为源码树内标准顺序：
  `mrproper → config → prepare → modules_prepare`（用户建议的顺序，已验证解决）。
- `flask.h` Not found：SELinux 私有头由 genheaders 从 classmap.h 生成，out-of-tree 不触发。
  加步骤编译 genheaders 并生成 flask.h/av_permissions.h 到 security/selinux/include/。
- **`SYSCALL_TABLE_HOOK` 死路**：源码 syscall_table_hook.c:36 硬性 `#error requires kernel >= 4.17
  (pt_regs syscall ABI)`，4.14 直接编译失败。改用 `CONFIG_KSU_KPROBES_HOOK=y`。
  注意：KPROBES_HOOK 实际用 `register_trace_sys_enter` tracepoint，不是真 kprobe；只是 Kconfig
  依赖需要 KPROBES，故在 config 里打开 CONFIG_KPROBES=y/KRETPROBES=y（设备内核 HAVE_KPROBES=y 支持）。
- `preempt_enable_no_resched_notrace` 未声明：4.14 的 include/linux/preempt.h 在 `#ifdef MODULE`
  下会 `#undef` 该宏（模块禁用）。加补丁把它替换成模块合法的 `preempt_enable_notrace()`。
