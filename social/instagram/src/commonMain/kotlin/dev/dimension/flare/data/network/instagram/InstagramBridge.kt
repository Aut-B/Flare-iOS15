package dev.dimension.flare.data.network.instagram

/**
 * 把 Kotlin 侧登录拿到的 cookie 交给宿主。
 *
 * Instagram 的原生 Swift 页面有自己的 `InstagramStore`，和 Kotlin 账号库是两套
 * 存储。登录成功后同步一次，用户从侧边栏 / 账号标签进原生页时就不必再登一遍。
 */
public interface InstagramBridge {
    /** 返回是否被接受（没有 `sessionid` 会被拒）。 */
    public fun adopt(cookie: String): Boolean
}

public object InstagramBridgeHolder {
    public var bridge: InstagramBridge? = null
}
