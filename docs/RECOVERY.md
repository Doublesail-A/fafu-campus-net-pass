# 恢复与排错

## 安装器回滚

安装前会保存 `/root/fafu-install-日期时间/etc-before.tar.gz` 和被替换的程序。回滚命令由安装器输出，例如：

```sh
sh /root/fafu-install-YYYYMMDD-HHMMSS/rollback.sh
```

**这个安装器回滚会恢复安装前的整个/etc，包括当时的设备/OTP/订阅配置。** 回滚前的当前/etc会另存 `etc-at-rollback.tar.gz`，防止后来新加的数据丢失。它与生产维护中“只恢复某次nft优化、保留现有数据库”的小范围回滚不同。只恢复到已知时间点，不要从GitHub下载别人的备份使用。

当前生产路由器已有历史分步备份；其路径不作为通用部署命令写入本教程。维护前再次备份，按对应变更的恢复脚本执行。

## 症状与排查

| 症状 | 优先检查 |
| --- | --- |
| 所有设备突然无法上网 | 路由器本机连通、校园认证状态、WAN默认路由；随后查核心监听 |
| 直连正常，代理都超时 | 节点是否失效、订阅是否过期、两端配置是否相同、当前selector |
| 部分网页或图片慢 | 同目标的DNS/TCP/TLS/TTFB；CDN、节点到目标路由、HTTP/2复用 |
| OTP一直错误 | 路由器时间、当前认证器密钥、上一台设备是否已使用同一码 |
| 登记成功后仍受限 | 当前MAC是否变化、授权enabled、nft set、旧客户端连接/代理设置 |
| 重启后代理核心反复崩溃 | `/tmp/privacy-proxy`是否在启动前创建为700，cache文件是否600 |
| 网站报证书错误 | 检查是否仍有旧MITM路径、终端代理/证书设置、源站证书；不要关闭TLS验证 |
| 页面仍是旧样式 | 重新登录LuCI、资源版本路径及rpcd/浏览器缓存 |

## 常用只读命令

```sh
/usr/sbin/privacy-access-status
/usr/sbin/privacy-proxy status
nft list table inet privacy_policy
netstat -lnt
free
cat /proc/loadavg
logread | tail -50
```

状态输出可能包含真实MAC、备注、节点标签；原始日志只供本机诊断，不直接提交到公开仓库。

## 避免增加故障

不要看到一次测速失败就重启整个网络。先判断上游是否要求重新认证、目标是否限流、节点是否可用。代理URLTest结果只是对一个指定URL的结果；不同URL的延迟或丢包可能完全不同。

不要手工清空整个nft规则集、关闭白名单来试速度；也不要把输入流量的FORWARD计数误当成所有中继连接的计数。透明中继收到的设备连接走INPUT，新建出口走OUTPUT，监测与任何并发策略必须覆盖实际路径。
