# 注意，又改了DTS，作者自测通过，没广泛测试

修改DTS的提交 -> https://github.com/coolsnowwolf/lede/pull/13604/commits/8e054e6759ff4c1e4f5cfe286c7826a7de3694e3

自测工作正常组合：

| 序号 | M.2 WiFi | M.2 5G | mPCIe 1 | mPCIe 2 |
|------|----------|--------|---------|---------|
| 1 | 空 | RM500Q-GL | MT7916 | 空 |
| 2 | MT7922 | RM500Q-GL | T99W373 | MT7916 |
| 3 | 空 | 空 | MT7916 | T99W373 |

第一次使用前请先阅读 [README.md](https://github.com/zzzz0317/lede-xgp-auto-build/blob/main/README.md)

通过转接板连接的 PCIe 5G 模块在刷机后需要断电（直接拔DC插头，拔市电那头要多等几秒电容放电）一次，否则大概率找不到模块，转接板硬件原因导致模块在重启时不能正常下电。

