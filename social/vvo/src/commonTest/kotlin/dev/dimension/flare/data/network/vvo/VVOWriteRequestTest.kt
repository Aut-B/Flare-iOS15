package dev.dimension.flare.data.network.vvo

import dev.dimension.flare.data.datasource.vvo.toVvoVisible
import dev.dimension.flare.data.platform.VVoCredential
import dev.dimension.flare.ui.model.UiTimelineV2
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
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

class VVOWriteRequestTest {
    @Test
    fun publicVisibilityOmitsVisibleField() {
        assertNull(UiTimelineV2.Post.Visibility.Public.toVvoVisible())
        assertEquals("1", UiTimelineV2.Post.Visibility.Private.toVvoVisible())
        assertEquals("6", UiTimelineV2.Post.Visibility.Mutual.toVvoVisible())
        assertEquals("10", UiTimelineV2.Post.Visibility.Followers.toVvoVisible())
    }

    @Test
    fun publicRepostDoesNotSendVisible() =
        runTest {
            var form: FormDataContent? = null
            val service = writeService { request -> form = request.body as FormDataContent }

            service.repostStatus(
                id = "status-id",
                content = "hello",
                st = "st-value",
            )

            val fields = requireNotNull(form).formData
            assertFalse(fields.contains("visible"))
            assertEquals("status-id", fields["id"])
            assertEquals("st-value", fields["st"])
        }

    @Test
    fun privateVisibilityKeepsExplicitVisibleField() =
        runTest {
            var form: FormDataContent? = null
            val service = writeService { request -> form = request.body as FormDataContent }

            service.updateStatus(
                content = "hello",
                st = "st-value",
                visible = UiTimelineV2.Post.Visibility.Private.toVvoVisible(),
            )

            assertEquals("1", requireNotNull(form).formData["visible"])
        }

    @Test
    fun freshConfigBypassesCachedStForEveryWrite() =
        runTest {
            var configCalls = 0
            val configSts = mutableListOf("st-1", "st-2", "st-3")
            val service =
                writeService(
                    credentialFlow = MutableStateFlow(VVoCredential(chocolate = "MLOGIN=1; SUB=test-sub")),
                    nextConfigSt = { configSts.removeAt(0) },
                ) { request ->
                    if (request.url.encodedPath == "/api/config") {
                        configCalls += 1
                    }
                }

            assertEquals("st-1", service.freshConfig().data?.st)
            assertEquals("st-2", service.freshConfig().data?.st)
            assertEquals("st-3", service.freshConfig().data?.st)
            assertEquals(3, configCalls)
        }

    private fun writeService(
        credentialFlow: MutableStateFlow<VVoCredential> =
            MutableStateFlow(VVoCredential(chocolate = "MLOGIN=1; SUB=test-sub")),
        nextConfigSt: () -> String = { "st-value" },
        onRequest: (HttpRequestData) -> Unit = {},
    ): VVOService =
        VVOService(
            credentialFlow = credentialFlow,
            httpClientFactory = mockHttpClientFactory { request ->
                onRequest(request)
                when (request.url.encodedPath) {
                    "/api/config" -> {
                        val st = nextConfigSt()
                        jsonResponse(
                            """
                            {"ok":1,"data":{"login":true,"st":"$st","uid":"uid"}}
                            """.trimIndent(),
                        )
                    }

                    else -> jsonResponse("""{"ok":1,"data":{}}""")
                }
            },
        )

    private fun mockHttpClientFactory(
        handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData,
    ): (HttpClientConfig<*>.() -> Unit) -> HttpClient =
        { config ->
            HttpClient(MockEngine { request -> handler(request) }) {
                config.invoke(this)
            }
        }

    private fun MockRequestHandleScope.jsonResponse(body: String): HttpResponseData =
        respond(
            content = body,
            status = HttpStatusCode.OK,
            headers =
                Headers.build {
                    append(HttpHeaders.ContentType, "application/json")
                },
        )
}
