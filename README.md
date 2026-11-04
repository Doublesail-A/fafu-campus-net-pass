# fafu-campus-net-pass

面向 OpenWrt/Kwrt 的设备接入、TCP 透明中继与按设备分流方案。HTTPS 保持端到端加密，不做 MITM，不要求终端安装路由器 CA。

当前整理内容包括完整管理代码、OTP 接入页、MAC 白名单和人员分组、FlClash/Clash 本地配置导入、共享节点与规则/全局分流、性能诊断、两天监测及部署/回滚说明。代码与分步教程将随本次整理提交。

## 致谢

感谢 [YifanHere/campus-net-nat-bypass](https://github.com/YifanHere/campus-net-nat-bypass/) 对 TCP 重新发起、DNS/IPv6 一致性、验证方法和掉线恢复思路的梳理，为本方案调整提供了重要帮助。本仓库采用不同的 nftables、Squid splice、sing-box 和 LuCI 实现；对检测机制的判断与实测范围将分别说明。

所有密码、订阅令牌、TOTP 密钥、证书私钥、真实设备列表和浏览器 cookies 均不随仓库上传。
