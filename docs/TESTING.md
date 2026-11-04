# 测试和验证范围

## 本地页面逻辑

在安装Node.js的电脑、仓库根目录执行：

```sh
node portal-transport-test.cjs
node people-ui-test.cjs
node devices-ui-test.cjs
node proxy-ui-test.cjs
```

覆盖OTP-only表单、私有MAC、无CA/checkbox、人员新建/改名/移动/删除、备注和名称的显示、节点/时长/只读权限。它们不等价于浏览器完整视觉/性能测试。

## 路由器侧隔离测试

```sh
sh scripts/check-source.sh
```

测试需要root、ip-full的网络命名空间、nft、nginx、openssl及已列依赖。权限测试建立三个隔离命名空间，包含两条虚拟WAN，不触碰真实客户端。使用自签名的**测试源站/监听器**，因此测试里需要信任fixture CA；这不代表生产透传需要安装CA。

测试覆盖未知MAC、相同IP冒用、静态IP、显式代理端口、IPv6、普通/IoT/临时路径、期限、长期模式、撤权中的已有连接、无效输入、配置失败回滚；TOTP测试覆盖标准向量、重放、CSRF与限流。核心测试使用真实sing-box进行配置检查。

新机安装器的`--check`在现有环境作只读检查。尚未在空白固件执行整套安装、真实断电冷启动和所有依赖包组合；不要把语法/隔离测试写成已完成这些验证。

## 真实TCP重建

用独立测试设备抓取LAN和WAN的SYN，比较同一目标的ISN、选项与实际连接端点。看到不同ISN以及路由器发起的新连接，才能支持“重新建连”；只看NAT或TTL不够。生产受测普通/IoT HTTPS及非网页TCP均已验证。

测试过程中要记清是否用了代理、是否同一节点、浏览器是否经电脑TUN、使用的测速URL、缓存状态、客户端CPU是否也跑在路由器上。只报告测量实际覆盖的范围。
