package com.mikyllyn.edgerank

import android.os.PowerManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.ExperimentalCoroutinesApi
import okhttp3.ConnectionPool
import okhttp3.Dns
import okhttp3.EventListener
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import kotlin.coroutines.coroutineContext
import kotlin.math.sqrt

private val IPV4 = Regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$")

data class Probe(val code: Int, val timeSec: Double, val match: Int)

data class Row(
    val ip: String,
    val ok: Int,
    val fail: Int,
    val score: Double,
    val medMs: Int,
    val avgMs: Int,
    val p95Ms: Int,
    val minMs: Int,
    val maxMs: Int,
    val jitMs: Double,
    val codes: String
)

/** Build the ranked-results CSV (used by the WebView saver and /dl endpoint). */
fun buildCsv(): String {
    val sb = StringBuilder("rank,ip,ok,fail,score,med_ms,avg_ms,p95_ms,min_ms,max_ms,jit_ms,codes\n")
    State.results.forEachIndexed { i, r ->
        sb.append("${i + 1},${r.ip},${r.ok},${r.fail},${String.format("%.1f", r.score)},")
            .append("${r.medMs},${r.avgMs},${r.p95Ms},${r.minMs},${r.maxMs},${String.format("%.1f", r.jitMs)},")
            .append("\"${r.codes}\"\n")
    }
    return sb.toString()
}

/** Shared, process-wide state for the web UI. */
object State {
    @Volatile var running = false
    @Volatile var job: Job? = null
    private val progress = StringBuilder()
    @Volatile var meta = ""
    @Volatile var results: List<Row> = emptyList()
    @Volatile var edges: List<String> = emptyList()
    @Volatile var ipsOk: List<String> = emptyList()

    @Volatile var bgpRunning = false
    private val bgpLog = StringBuilder()

    val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    fun log(s: String) { synchronized(progress) { progress.append(s).append('\n') } }
    fun progressText(): String = synchronized(progress) { progress.toString() }
    fun resetProgress() { synchronized(progress) { progress.setLength(0) } }

    fun bgpLog(s: String) { synchronized(bgpLog) { bgpLog.append(s).append('\n') } }
    fun bgpLogText(): String = synchronized(bgpLog) { bgpLog.toString() }
    fun bgpReset() { synchronized(bgpLog) { bgpLog.setLength(0) } }

    /** Lazily ensure the default edge list exists (expanded fallback CDNvideo ranges). */
    fun ensureEdges() {
        if (edges.isEmpty()) edges = Edges.fallbackExpanded()
    }
}

object Prober {

    // curl -k equivalent: accept any certificate / hostname.
    private val trustAll = object : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out java.security.cert.X509Certificate>?, authType: String?) {}
        override fun checkServerTrusted(chain: Array<out java.security.cert.X509Certificate>?, authType: String?) {}
        override fun getAcceptedIssuers(): Array<java.security.cert.X509Certificate> = arrayOf()
    }
    private val trustAllFactory = SSLContext.getInstance("TLS").apply {
        init(null, arrayOf(trustAll), java.security.SecureRandom())
    }.socketFactory

    /** Base client for edge probing: no proxy, no redirects, fresh connection each call. */
    private val probeBase: OkHttpClient = OkHttpClient.Builder()
        .proxy(Proxy.NO_PROXY)
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(6, TimeUnit.SECONDS)
        .callTimeout(6, TimeUnit.SECONDS)
        .connectionPool(ConnectionPool(0, 1, TimeUnit.SECONDS))
        .sslSocketFactory(trustAllFactory, trustAll)
        .hostnameVerifier { _, _ -> true }
        .build()

    /** General client for API calls (RIPEstat, DoH, ipify) — normal TLS, follows redirects. */
    val apiClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .callTimeout(25, TimeUnit.SECONDS)
        .build()

    private fun clientFor(ip: String): OkHttpClient =
        probeBase.newBuilder().dns(object : Dns {
            override fun lookup(hostname: String): List<InetAddress> =
                listOf(InetAddress.getByName(ip))
        }).build()

    private fun oneProbe(client: OkHttpClient, domain: String, path: String, mhdr: String): Probe {
        return try {
            val req = Request.Builder()
                .url("https://$domain$path")
                .header("Connection", "close")
                .header("User-Agent", "edgerank/1.0")
                .build()
            val t0 = System.nanoTime()
            client.newCall(req).execute().use { resp ->
                val dt = (System.nanoTime() - t0) / 1e9
                val m = if (mhdr.isNotEmpty()) (if (resp.header(mhdr) != null) 1 else 0) else 1
                Probe(resp.code, dt, m)
            }
        } catch (e: Exception) {
            Probe(0, 0.0, 1)
        }
    }

    private fun isOk(p: Probe, ecode: Int): Boolean =
        if (ecode != 0) p.code == ecode else p.code != 0

    @OptIn(ExperimentalCoroutinesApi::class)
    private suspend fun probePool(
        domain: String, path: String, ips: List<String>,
        rounds: Int, conc: Int, ecode: Int, mhdr: String, label: String
    ): Map<String, List<Probe>> = coroutineScope {
        // limitedParallelism on IO can exceed the default ~64-thread cap for I/O-bound
        // work, so `conc` (e.g. 64-256) is the real number of simultaneous probes.
        // Timeouts stay at probeBase's 5s/6s (NOT shortened) so DPI edges aren't dropped.
        val io = Dispatchers.IO.limitedParallelism(if (conc < 1) 1 else conc)
        val out = ConcurrentHashMap<String, List<Probe>>()
        val done = AtomicInteger()
        val total = ips.size
        val tasks = ips.map { ip ->
            async(io) {
                coroutineContext.ensureActive()
                val client = clientFor(ip)
                val list = ArrayList<Probe>(rounds)
                repeat(rounds) {
                    coroutineContext.ensureActive()
                    list.add(oneProbe(client, domain, path, mhdr))
                }
                out[ip] = list
                val c = done.incrementAndGet()
                if (c % 500 == 0 || c == total) State.log("  $label: $c/$total ...")
            }
        }
        tasks.awaitAll()
        out
    }

    private fun computeRow(ip: String, probes: List<Probe>, rounds: Int, ecode: Int): Row {
        val okTimes = ArrayList<Double>()
        val codes = LinkedHashMap<Int, Int>()
        for (p in probes) {
            codes[p.code] = (codes[p.code] ?: 0) + 1
            if (isOk(p, ecode) && p.match == 1) okTimes.add(p.timeSec)
        }
        okTimes.sort()
        val nt = okTimes.size
        val okc = nt
        val fail = rounds - okc
        val med = if (nt > 0) {
            if (nt % 2 == 1) okTimes[nt / 2] else (okTimes[nt / 2 - 1] + okTimes[nt / 2]) / 2.0
        } else 0.0
        val p95 = if (nt > 0) okTimes[Math.round((nt - 1) * 0.95).toInt()] else 0.0
        val mn = if (nt > 0) okTimes[0] else 0.0
        val mx = if (nt > 0) okTimes[nt - 1] else 0.0
        val avg = if (nt > 0) okTimes.sum() / nt else 0.0
        val jit = if (nt > 1) {
            val v = okTimes.sumOf { (it - avg) * (it - avg) } / nt
            sqrt(v)
        } else 0.0
        val succ = if (rounds > 0) okc.toDouble() / rounds else 0.0
        var score = succ * 100 - med * 20 - jit * 15
        if (score < 0) score = 0.0
        val cs = codes.entries.joinToString(" ") {
            "${if (it.key == 0) "000" else it.key.toString()}:${it.value}"
        }
        return Row(
            ip, okc, fail, Math.round(score * 10) / 10.0,
            (med * 1000).toInt(), (avg * 1000).toInt(), (p95 * 1000).toInt(),
            (mn * 1000).toInt(), (mx * 1000).toInt(),
            Math.round(jit * 1000 * 10) / 10.0, cs
        )
    }

    private const val BROWSER_UA =
        "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

    // Клиент для vantage. Умеренный таймаут: vantage теперь идёт ДО скана.
    private val vantageClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .callTimeout(12, TimeUnit.SECONDS)
        .build()

    private fun vget(url: String): String? = try {
        vantageClient.newCall(
            Request.Builder().url(url)
                .header("User-Agent", BROWSER_UA)
                .header("Accept", "text/html,application/json,*/*")
                .header("Accept-Language", "ru,en;q=0.9")
                .build()
        ).execute().use { if (it.isSuccessful) it.body?.string() else null }
    } catch (e: Throwable) { null }

    /** Vantage через Яндекс Интернетометр — для белых списков. С диагностикой. */
    private fun yandexVantage(): Boolean {
        var apiStatus = -1
        var apiBody = ""
        try {
            vantageClient.newCall(
                Request.Builder()
                    .url("https://yandex.ru/internet/api/v0/ip")
                    .header("User-Agent", BROWSER_UA)
                    .header("Accept", "application/json,text/plain,*/*")
                    .header("Accept-Language", "ru,en;q=0.9")
                    .build()
            ).execute().use {
                apiStatus = it.code
                apiBody = it.body?.string() ?: ""
            }
        } catch (e: Throwable) {
            State.log("vantage(Яндекс): запрос IP упал — ${e.message}")
        }
        val page = vget("https://yandex.ru/internet/") ?: ""
        var ip = apiBody.trim().trim('"')
        if (!IPV4.matches(ip)) ip = Regex("\"v4\":\"([^\"]*)\"").find(page)?.groupValues?.get(1) ?: ""
        if (!IPV4.matches(ip)) {
            val snip = apiBody.take(120).replace(Regex("\\s+"), " ").trim()
            State.log("vantage(Яндекс): IP не получен. api HTTP=$apiStatus, ответ: «$snip»")
            State.log("vantage(Яндекс): страница /internet ${if (page.isEmpty()) "не открылась" else "открылась (${page.length} б)"}")
            return false
        }
        val ispBlock = Regex("\"isp\":\\{([^}]*)}").find(page)?.groupValues?.get(1) ?: ""
        val isp = Regex("\"localName\":\"([^\"]*)\"").find(ispBlock)?.groupValues?.get(1) ?: ""
        val asn = Regex("\"asn\":\\[([0-9,]*)]").find(ispBlock)?.groupValues?.get(1) ?: ""
        val vpn = when (Regex("\"isVpn\":(true|false)").find(ispBlock)?.groupValues?.get(1)) {
            "true" -> "да"; "false" -> "нет"; else -> "?"
        }
        val provider = when {
            isp.isNotEmpty() -> "$isp   |  VPN по мнению Яндекса: $vpn"
            asn.isNotEmpty() -> "имя не указано (ASN $asn)   |  VPN: $vpn"
            else -> "Яндекс не отдал имя провайдера для этой сети"
        }
        State.log("==============================================================")
        State.log(" ТЕСТ ИДЁТ С IP: $ip   (источник: Яндекс Интернетометр)")
        State.log("   провайдер:   $provider")
        State.log("   ASN:         ${asn.ifEmpty { "?" }}")
        State.log("   -> это ТВОЙ провайдер? если нет — VPN включён, выключи его.")
        State.log("==============================================================")
        return true
    }

    /**
     * Best-effort vantage. Вызывается из ОТДЕЛЬНОЙ корутины, поэтому не может ни
     * задержать, ни оборвать замер. Яндекс (белые списки) -> ip-api -> ipify.
     */
    private fun showVantage(): Boolean {
        if (yandexVantage()) return true
        try {
            val line = apiClient.newCall(
                Request.Builder()
                    .url("http://ip-api.com/line/?fields=query,country,city,isp,as")
                    .build()
            ).execute().use { it.body?.string() ?: "" }
            val parts = line.trim().lines()
            val ip = parts.getOrNull(0)?.trim() ?: ""
            if (IPV4.matches(ip)) {
                State.log("==============================================================")
                State.log(" ТЕСТ ИДЁТ С IP: $ip")
                State.log("   регион:      ${parts.getOrNull(1) ?: "?"} / ${parts.getOrNull(2) ?: "?"}")
                State.log("   провайдер:   ${parts.getOrNull(3) ?: "?"}")
                State.log("   ASN:         ${parts.getOrNull(4) ?: "?"}")
                State.log("   -> это ТВОЙ провайдер? если нет — VPN включён, выключи его.")
                State.log("==============================================================")
                return true
            }
        } catch (e: Exception) { /* fall through */ }
        try {
            val ip2 = apiClient.newCall(
                Request.Builder().url("https://api.ipify.org").build()
            ).execute().use { it.body?.string()?.trim() ?: "" }
            if (IPV4.matches(ip2)) {
                State.log("ТЕСТ ИДЁТ С IP: $ip2  (проверь, что это твой провайдер, а не VPN)")
                return true
            }
        } catch (e: Exception) { /* fall through */ }
        State.log(" Внешний IP не определён (ip-api/ipify не ответили).")
        State.log("   Если это обычная сеть — проверь интернет. Под белым списком это норма, на замер не влияет.")
        return false
    }

    private suspend fun runRank(
        domain: String, path: String, rounds: Int, conc: Int, ecode: Int,
        mhdr: String, src: List<String>
    ) {
        State.resetProgress()
        State.results = emptyList()

        var ips = src.filter { IPV4.matches(it) }.distinct()
        if (ips.isEmpty()) { State.log("Нет кандидатов IP (список пуст)."); return }

        // Внешний IP определяем ДО скана. Обёрнуто в try/catch(Throwable), поэтому
        // vantage не может оборвать замер (детач-версия доказала: запрос к Яндексу
        // пробам не мешает, а от исключения защищает обёртка).
        try { showVantage() } catch (e: Throwable) { State.log("vantage: ${e.message}") }
        State.log("domain=$domain  path=$path  candidates=${ips.size}")
        State.log("rounds=$rounds timeout=6s concurrency=$conc expected_code=${if (ecode == 0) "any" else ecode}")

        // phase 1: screening
        if (ips.size > 50) {
            State.log("")
            State.log("phase 1: screening ${ips.size} IPs (1 round each)...")
            val screen = probePool(domain, path, ips, 1, conc, ecode, mhdr, "screen")
            val survivors = ips.filter { ip ->
                screen[ip]?.any { isOk(it, ecode) && it.match == 1 } == true
            }
            State.log("phase 1: ${survivors.size} of ${ips.size} responded.")
            if (survivors.isEmpty()) { State.log("Nothing survived screening."); return }
            ips = survivors
        }

        // phase 2: full probe
        State.log("")
        State.log("phase 2: full probe of ${ips.size} IPs ($rounds rounds each)...")
        val res = probePool(domain, path, ips, rounds, conc, ecode, mhdr, "probe")

        val rows = ips.mapNotNull { ip -> res[ip]?.let { computeRow(ip, it, rounds, ecode) } }
            .sortedWith(compareByDescending<Row> { it.score }.thenBy { it.medMs })
        State.results = rows
        State.ipsOk = rows.filter { it.ok >= 1 }.map { it.ip }
        State.log("")
        State.log("ranked ${rows.size} edges.")
    }

    fun startRun(
        domain: String, path: String, rounds: Int, conc: Int, ecode: Int,
        mhdr: String, src: List<String>
    ) {
        if (State.running) return
        State.running = true
        try { ProbeService.start(App.instance) } catch (e: Throwable) {}
        val pm = App.instance.getSystemService(PowerManager::class.java)
        val wl = pm?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "edgerank:probe")
        try { wl?.acquire(60 * 60 * 1000L) } catch (e: Exception) {}
        State.job = State.scope.launch {
            try {
                runRank(domain, path, rounds, conc, ecode, mhdr, src)
            } catch (e: CancellationException) {
                State.log("замер отменён.")
            } catch (e: Exception) {
                State.log("ошибка: ${e.message}")
            } finally {
                State.running = false
                try { if (wl?.isHeld == true) wl.release() } catch (e: Exception) {}
                try { ProbeService.stop(App.instance) } catch (e: Throwable) {}
            }
        }
    }

    fun cancel() {
        State.job?.cancel()
        State.running = false
    }

    /** Resolve a CDN domain -> connected edge IP -> backend ASN (via RIPEstat). */
    suspend fun resolve(domain: String): Triple<String?, String?, String> {
        val ipHolder = arrayOfNulls<String>(1)
        val c = apiClient.newBuilder()
            .callTimeout(8, TimeUnit.SECONDS)
            .eventListener(object : EventListener() {
                override fun connectEnd(
                    call: okhttp3.Call, inetSocketAddress: InetSocketAddress,
                    proxy: Proxy, protocol: okhttp3.Protocol?
                ) { ipHolder[0] = inetSocketAddress.address.hostAddress }
            })
            .sslSocketFactory(trustAllFactory, trustAll)
            .hostnameVerifier { _, _ -> true }
            .build()
        try {
            c.newCall(Request.Builder().url("https://$domain/").build()).execute().use {}
        } catch (e: Exception) { /* ignore, we only need connected IP */ }
        val edgeIp = ipHolder[0]

        // CNAME via Google DoH (best-effort)
        var cname: String? = null
        try {
            val body = apiClient.newCall(
                Request.Builder().url("https://dns.google/resolve?name=$domain&type=A").build()
            ).execute().use { it.body?.string() ?: "" }
            val ans = JSONObject(body).optJSONArray("Answer")
            if (ans != null) {
                for (i in 0 until ans.length()) {
                    val d = ans.getJSONObject(i).optString("data")
                    if (d.isNotEmpty() && !IPV4.matches(d)) cname = d
                }
            }
        } catch (e: Exception) {}

        val sb = StringBuilder()
        if (edgeIp != null && IPV4.matches(edgeIp)) {
            try {
                val ov = apiClient.newCall(
                    Request.Builder()
                        .url("https://stat.ripe.net/data/prefix-overview/data.json?resource=$edgeIp")
                        .build()
                ).execute().use { it.body?.string() ?: "" }
                val data = JSONObject(ov).optJSONObject("data")
                val asns = data?.optJSONArray("asns")
                val asn = if (asns != null && asns.length() > 0)
                    asns.getJSONObject(0).optString("asn") else ""
                val holder = if (asns != null && asns.length() > 0)
                    asns.getJSONObject(0).optString("holder") else ""
                val prefix = data?.optString("resource") ?: ""
                sb.append("asn=$asn|holder=$holder|prefix=$prefix")
            } catch (e: Exception) {
                sb.append("err=ripestat")
            }
        }
        return Triple(edgeIp, cname, sb.toString())
    }
}
