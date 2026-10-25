# bbport-cusa02716

《假面骑士 穿越战争 创生》(Kamen Rider Battride War Genesis, **CUSA02716**) 的 Android 移植 —— 云构建仓库。

本仓库**不含**移植源码，只放两样东西：

| 路径 | 作用 |
|---|---|
| `patch/cusa02716-runtime.patch` | 对上游 [`ducvd89/Bloodborne-Android`](https://github.com/ducvd89/Bloodborne-Android) 的改动（29 个文件） |
| `build.sh` | 分阶段构建脚本 |
| `.github/workflows/build.yml` | CI：检出上游 → 打补丁 → 编 runtime → 出 APK |

## 补丁内容

把血源的运行时改成能跑本作：

1. **NID 键回退**（`src/*.c`，89 处）—— 运行时 key 是 `nid#库序号#模块序号`，库序号是每个镜像自己的槽位号。血源拼 `p#J`，本作拼 `g#d`，所以照别的游戏写死的表 `strcmp` 全不中。改成前 11 字符 NID 比较后，pthread / mutex / cond / rwlock / sema 的实现全部解锁。
2. **新增 EventFlag**（`gpu/shadps4/core/libraries/kernel/eventflag.*`）—— 本作主循环要的 6 条，上游有实现但 fork 没带；顺带修了 `Clear()` 的 `&= bits` → `&= ~bits`。
3. **新增 zlib**（`gpu/shadps4/core/libraries/zlib/`）—— 5 条，用已链接的 miniz 实际解压 `_fpk` 资源包。
4. **补 37 条缺失导入** —— RTC 4 条、时间转换、module info、`get_authinfo`、AppContent 3 条、condattr、`sincosf` 等。
5. **CI 适配** —— 去掉 `taskset -c 2-23`（runner 只有 4 核）、头文件包缺失时回退系统包、无游戏图标时不中断。

## 怎么跑

`Actions` → `Build CUSA02716 APK` → `Run workflow`。

`stage` 参数可以只跑某一段：

- `headers` — 装 Boost / magic_enum / robin-map / VMA（几十秒）
- `deps` — 交叉编译 ffmpeg / openssl / protobuf / SDL3（**最慢，30-60 分钟**）
- `bionic` — 编 libbbcpu / libbbgpu / bb-probe
- `apk` — 打包签名
- `all` — 全流程

产物在 run 页面的 Artifacts 里（`apk-<run号>`），失败时还会有 `logs-<run号>`。

## APK 里没有游戏数据

这是上游的设计：APK 只含运行时。游戏本体和 `libbbaot.so`（AOT 重编译产物，用 bb-recomp 在你自己的 PC 上从你的 eboot 生成）要单独放进设备：

```
/data/data/<包名>/files/bbport/aot/libbbaot.so
```

## 版权

补丁只改运行时/CI 代码，不包含任何游戏资产。游戏文件、`libbbaot.so` 均由使用者用自己的正版游戏生成，不进本仓库、不进 APK。
