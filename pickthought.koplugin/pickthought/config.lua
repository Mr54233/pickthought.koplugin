local C = {
    NAME = "撷思",
    VERSION = "0.1.0",
    SCHEMA = 1,
    PLUGIN_DIR = "pickthought.koplugin",
    DATA_DIR = "pickthought",

    -- 更新清单固定保存在仓库根目录；清单中的下载地址指向
    -- GitHub Release 全量包。旧版本仍可通过备用地址升级到本版本。
    UPDATE_MANIFEST = "https://raw.githubusercontent.com/Mr54233/pickthought.koplugin/main/update.json",
    UPDATE_MANIFESTS = {
        "https://raw.githubusercontent.com/Mr54233/pickthought.koplugin/main/update.json",
    },

    -- 仅作为 GitHub 官方资源访问失败时的回退入口。
    -- 下载后仍会执行大小与 SHA-256 校验，镜像不能改变安装内容。
    GITHUB_MIRRORS = {
        "https://ghfast.top/",
        "https://gh-proxy.com/",
        "https://ghproxy.net/",
    },

    READ_INTERVAL = 30,
    IDLE_TIMEOUT = 600,
    REMOTE_THRESHOLD = 2,
}
return C
