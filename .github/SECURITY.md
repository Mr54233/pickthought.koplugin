# 安全政策

## 支持的版本

撷思只对最新发布版本提供安全修复,请保持 OTA 更新:

| 版本 | 支持 |
| ---- | ---- |
| 最新 Release | ✅ |
| 旧版本 | ❌ |

## 报告漏洞

发现安全漏洞时,**请不要开公开 issue**,请使用 [GitHub 私密漏洞报告](https://github.com/Mr54233/pickthought.koplugin/security/advisories/new):

1. 进入仓库 Security 页签,选择 "Report a vulnerability";
2. 描述问题、复现条件与影响范围,可附日志片段(注意先抹掉其中的 Cookie、token 等凭据);
3. 我们会在收到报告后尽快回应。

## 报告范围

- 插件处理书源数据(EPUB/微读接口响应)时的崩溃或内存破坏
- 凭据(Cookie)的意外泄漏或不当持久化
- 供应链问题(依赖的 GitHub Action 或工具链被投毒)

以下不在安全范围,请走普通 issue 或 Discussions:

- 微信读书非公开接口的变动导致的同步失败
- 需要物理接触设备或已 root 设备才能利用的问题
