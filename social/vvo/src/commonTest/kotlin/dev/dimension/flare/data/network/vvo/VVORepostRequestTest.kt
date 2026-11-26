package dev.dimension.flare.data.network.vvo

import dev.dimension.flare.data.datasource.vvo.toVvoPicId
import dev.dimension.flare.data.platform.VVoCredential
import io.ktor.client.HttpClient
import io.ktor.client.HttpClientConfig
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import io.ktor.client.request.forms.FormDataContent
import io.ktor.http.Headers
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.Parameters
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull

/**
 * 微博转发请求对齐回归（W01 证据 A/B 级）。
 *
 * 公开转发只发 `{id, content, st, mid}`，`mid` 必须等于原微博 id；
 * 无附件时不发 `picId`；`User-Agent` / `X-Requested-With` / `MWeibo-Pwa` / `Origin`
 * 没有官方证据，不允许在本客户端伪造。UA 等 D 级项留待真机抓包后再改。
 */
class VVORepostRequestTest {
    @Test
    fun repostUsesOfficialEndpointAndOnlyOriginalStatusId() =
        runTest {
            var request: RepostRequest? = null
            val service = repostService { request = it.toRepostRequest() }

            service.repostStatus(
                id = "original-status-id",
                content = "hello #weibo#",
                st = "st-value",
            )

            val captured = requireNotNull(request)
            assertEquals(HttpMethod.Post, captured.method)
            assertEquals("https", captured.protocol)
            assertEquals("m.weibo.cn", captured.host)
            assertEquals("/api/statuses/repost", captured.path)
            assertEquals("x-www-form-urlencoded", captured.contentSubtype)
            assertEquals(setOf("id", "content", "st", "mid"), captured.form.names())
            assertEquals("original-status-id", captured.form["id"])
            assertEquals("original-status-id", captured.form["mid"])
            assertEquals("hello #weibo#", captured.form["content"])
            assertEquals("st-value", captured.form["st"])
            assertNull(captured.form["visible"])
            assertNull(captured.form["picId"])
        }

    @Test
    fun repostHeadersOnlyCarrySessionAndEvidenceBackedValues() =
        runTest {
            var headers: Headers? = null
            val service = repostService { headers = it.headers }

            service.repostStatus(
                id = "original-status-id",
                content = "hello",
                st = "st-value",
            )

            val captured = requireNotNull(headers)
            assertEquals("st-value", captured["X-Xsrf-Token"])
            assertEquals("MLOGIN=1; SUB=test-sub", captured[HttpHeaders.Cookie])
            assertEquals("https://m.weibo.cn/", captured["Referer"])
            assertNull(captured[HttpHeaders.UserAgent])
            assertNull(captured["X-Requested-With"])
            assertNull(captured["MWeibo-Pwa"])
            assertNull(captured["Origin"])
        }

    @Test
    fun repostWithAttachmentsSendsJoinedPicId() =
        runTest {
            var form: Parameters? = null
            val service = repostService { form = it.toRepostRequest().form }

            service.repostStatus(
                id = "original-status-id",
                content = "hello",
                st = "st-value",
                picId = listOf("100", "200").toVvoPicId(),
            )

            assertEquals("100,200", requireNotNull(form)["picId"])
        }

    @Test
    fun emptyMediaListMapsToNullPicId() {
        assertNull(emptyList<String>().toVvoPicId())
        assertEquals("100,200", listOf("100", "200").toVvoPicId())
    }

    private fun repostService(
        onRepost: (HttpRequestData) -> Unit,
    ): VVOService =
        VVOService(
            credentialFlow = flowOf(VVoCredential(chocolate = "MLOGIN=1; SUB=test-sub")),
            httpClientFactory = mockHttpClientFactory { request ->
                onRepost(request)
                respond(
                    content = """{"ok":1,"data":{"id":"reposted"}}""",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "application/json"),
                )
            },
        )

    private fun mockHttpClientFactory(
        handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData,
    ): (HttpClientConfig<*>.() -> Unit) -> HttpClient =
        { config ->
            HttpClient(
                MockEngine { request ->
                    handler(request)
                },
            ) {
                config.invoke(this)
            }
        }
}

private data class RepostRequest(
    val method: HttpMethod,
    val protocol: String,
    val host: String,
    val path: String,
    val contentSubtype: String?,
    val form: Parameters,
    val headers: Headers,
)

private fun HttpRequestData.toRepostRequest(): RepostRequest {
    val form = assertIs<FormDataContent>(body).formData
    return RepostRequest(
        method = method,
        protocol = url.protocol.name,
        host = url.host,
        path = url.encodedPath,
        contentSubtype = body.contentType?.contentSubtype,
        form = form,
        headers = headers,
    )
}
