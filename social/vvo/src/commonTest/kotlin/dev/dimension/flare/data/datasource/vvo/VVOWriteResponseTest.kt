package dev.dimension.flare.data.datasource.vvo

import dev.dimension.flare.data.network.vvo.model.VVOResponse
import kotlin.test.Test
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * 微博写接口的失败判定回归：
 * 服务端业务失败是 HTTP 200 + `ok=0`，不能当成成功。
 */
class VVOWriteResponseTest {
    @Test
    fun okZeroThrowsWithServerMessage() {
        val error =
            assertFailsWith<Exception> {
                VVOResponse<Any?>(data = null, ok = 0L, msg = "转发频繁", httpCode = 200L).requireOk()
            }
        assertTrue(error.message.orEmpty().contains("转发频繁"), "错误信息应包含服务端 msg，实际：${error.message}")
    }

    @Test
    fun non200Throws() {
        val error =
            assertFailsWith<Exception> {
                VVOResponse<Any?>(data = null, ok = 0L, msg = "server error", httpCode = 500L).requireOk()
            }
        assertTrue(error.message.orEmpty().contains("500"), "错误信息应包含 HTTP 状态码，实际：${error.message}")
    }

    @Test
    fun okOnePasses() {
        VVOResponse<Any?>(data = null, ok = 1L, msg = null, httpCode = 200L).requireOk()
    }

    @Test
    fun missingFieldsPass() {
        // 老接口有时不回 ok/http_code，不能因此误判失败。
        VVOResponse<Any?>().requireOk()
    }
}
