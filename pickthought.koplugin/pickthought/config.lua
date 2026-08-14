local C = {
    NAME = "撷思",
    VERSION = "0.3.0",
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

    AUTO_UPDATE_INTERVAL = 24 * 60 * 60,
    AUTO_UPDATE_RETRY_INTERVAL = 6 * 60 * 60,
    LOW_MEMORY_SETTING = "DGLOBAL_CACHE_FREE_PROPORTION",
    LOW_MEMORY_RATIO = 0.15,
    READ_INTERVAL = 30,
    IDLE_TIMEOUT = 600,
    REMOTE_THRESHOLD = 2,
}
return C
