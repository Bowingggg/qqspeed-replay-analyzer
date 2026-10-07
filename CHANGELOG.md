# Changelog

本文件记录各版本的差异。项目功能与使用说明见 `README.md`。

---

## v3.7.23

- 新增**同一录像不同圈之间的 A/B 对比**。
- 支持任意两个真实圈之间比较（圈1 vs 圈2、圈1 vs 圈3、圈2 vs 圈3 …）。
- 同录像两侧圈次**独立选择**，切换 A 圈不再强制同步 B 圈。
- 禁止同一圈与自身比较；只有一圈的录像不提供本录像圈间比较入口。
- 不同录像之间原有的 A/B 行为保持不变（含同圈号联动与本地高频 ↔ 联网低频影子比较）。
- 无 schema 变化，无需重建已有分析缓存。

## v3.7.22

- 正式采用 **MIT License**。
- 完成公开发布流程隔离与隐私门禁：白名单 manifest、隔离 public repo、隐私扫描、冷态验证。
- 增加 publisher regression，纳入 Fast Gate。
- 完成 First-run Bootstrap 的发布收口。
- 公开 README / CONTRIBUTING / LICENSE 改为受版本管理的公开文档源。

## v3.7.21

- 首个公开发行版本。
- 公开包包含：原生 telemetry、原生 Drift / action、官方地图路线、同图录像 A/B 对比。
