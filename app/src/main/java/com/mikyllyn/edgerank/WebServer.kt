package com.mikyllyn.edgerank

import fi.iki.elonen.NanoHTTPD
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.io.File

private val IP4 = Regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$")

class WebServer(port: Int) : NanoHTTPD("127.0.0.1", port) {

    override fun serve(session: IHTTPSession): Response {
        return try {
            route(session)
        } catch (e: Exception) {
            html("<p class=bad>Внутренняя ошибка: ${esc(e.message ?: "")}</p><a href='/'>назад</a>")
        }
    }

    private fun route(session: IHTTPSession): Response {
        if (session.uri == "/dl/out.csv") return csv()

        // Parse POST body (multipart/urlencoded) so form fields + files are available.
        val files = HashMap<String, String>()
        if (session.method == Method.POST) {
            try { session.parseBody(files) } catch (e: Exception) {}
        }
        val action = p(session, "action").ifEmpty { "home" }

        return when (action) {
            "run" -> doRun(session)
            "status" -> doStatus()
            "cancel" -> doCancel()
            "resolve" -> doResolve(session)
            "bgp" -> doBgp(session)
            "upload" -> doUpload(session, files)
            else -> doHome(session)
        }
    }

    // ---- actions ---------------------------------------------------------

    private fun doRun(session: IHTTPSession): Response {
        val domain = sd(p(session, "domain"))
        var path = sp(p(session, "path")); if (path.isEmpty()) path = "/"
        if (!path.startsWith("/")) path = "/$path"
        val rounds = sn(p(session, "rounds")).toIntOrNull() ?: 10
        val conc = sn(p(session, "conc")).toIntOrNull() ?: 16
        val ecode = sn(p(session, "ecode")).toIntOrNull() ?: 400
        val mhdr = shd(p(session, "mhdr"))

        if (domain.isEmpty())
            return html("<p class=bad>Пустой домен.</p><a href='/'>назад</a>")
        if (State.running)
            return html("<p class=warn>Уже выполняется. <a href='/?action=status'>Статус</a></p>")

        State.ensureEdges()
        val src = if (p(session, "src") == "ips_ok") State.ipsOk else State.edges
        State.meta = "$domain$path  rounds=$rounds  src=${if (p(session, "src") == "ips_ok") "ips_ok" else "edges.txt"} (${src.size} IP)"

        Prober.startRun(domain, path, rounds, conc, ecode, mhdr, src)
        return html(
            "<meta http-equiv=\"refresh\" content=\"2;url=/?action=status\">" +
                "<p>Запущено: <b>${esc(domain + path)}</b> (rounds=$rounds, IP=${src.size}). Переход к статусу…</p>"
        )
    }

    private fun doStatus(): Response {
        val sb = StringBuilder()
        if (State.running) {
            sb.append("<meta http-equiv=\"refresh\" content=\"3\">")
            sb.append("<h3>Идёт замер… <span class=warn>(автообновление каждые 3с)</span></h3>")
            sb.append(vbanner())
            if (State.meta.isNotEmpty()) sb.append("<p>${esc(State.meta)}</p>")
            sb.append("<pre>").append(esc(tail(State.progressText(), 16))).append("</pre>")
            sb.append("<p class=good>можно заблокировать экран — замер продолжится в фоне (уведомление активно).</p>")
            sb.append("<p><a href='/?action=cancel'>отменить замер</a> · <a href='/'>к форме</a></p>")
            return html(sb.toString(), sort = false)
        }

        sb.append("<h3>Готово ✓ &nbsp; <a href='/'>новый запуск</a></h3>")
        sb.append(vbanner())
        if (State.meta.isNotEmpty()) sb.append("<p>${esc(State.meta)}</p>")
        val rows = State.results
        if (rows.isNotEmpty()) {
            sb.append("<p>рабочих эджей: <b>${rows.count { it.ok >= 1 }}</b> &nbsp; ")
            sb.append("<a href='/dl/out.csv'>скачать CSV</a> &nbsp; ")
            sb.append("<span class=warn>(клик по заголовку — сортировка)</span></p>")
            sb.append("<table id=t data-c=-1 data-a=1><thead><tr>")
            val heads = listOf("#", "ip", "ok", "fail", "score", "med_ms", "p95_ms", "jit_ms", "codes")
            heads.forEachIndexed { i, h -> sb.append("<th onclick=\"srt('t',$i)\">$h</th>") }
            sb.append("</tr></thead><tbody>")
            rows.forEachIndexed { i, r ->
                val jc = if (r.jitMs < 20) "good" else if (r.jitMs < 60) "warn" else "bad"
                sb.append("<tr>")
                    .append("<td>${i + 1}</td>")
                    .append("<td>${esc(r.ip)}</td>")
                    .append("<td>${r.ok}</td>")
                    .append("<td>${r.fail}</td>")
                    .append("<td>${fmt1(r.score)}</td>")
                    .append("<td>${r.medMs}</td>")
                    .append("<td>${r.p95Ms}</td>")
                    .append("<td class=$jc>${fmt1(r.jitMs)}</td>")
                    .append("<td>${esc(r.codes)}</td>")
                    .append("</tr>")
            }
            sb.append("</tbody></table>")
        } else {
            sb.append("<p class=bad>Пусто — ничего не ответило (проверь домен/путь/заголовок).</p>")
        }
        return html(sb.toString(), sort = true)
    }

    private fun doCancel(): Response {
        Prober.cancel()
        return html("<meta http-equiv=\"refresh\" content=\"1;url=/\"><p class=warn>Замер остановлен.</p>")
    }

    private fun doResolve(session: IHTTPSession): Response {
        val d = sd(p(session, "d"))
        val sb = StringBuilder("<h3>Определение бэкенд-ASN &nbsp; <a href='/'>← назад</a></h3>")
        if (d.isEmpty()) return html("$sb<p class=bad>пустой домен.</p>")
        val (edgeIp, cname, info) = runBlocking { Prober.resolve(d) }
        sb.append("<pre>домен:   ${esc(d)}")
        if (!cname.isNullOrEmpty()) sb.append("\nCNAME:   -> ${esc(cname)}")
        sb.append("\nedge IP: ${esc(edgeIp ?: "?")}</pre>")
        if (edgeIp != null && IP4.matches(edgeIp)) {
            val map = info.split("|").mapNotNull {
                val kv = it.split("=", limit = 2); if (kv.size == 2) kv[0] to kv[1] else null
            }.toMap()
            val asn = map["asn"] ?: ""
            if (asn.isNotEmpty()) {
                sb.append("<p class=good>бэкенд: <b>AS$asn</b> — ${esc(map["holder"] ?: "")}<br>")
                sb.append("префикс: ${esc(map["prefix"] ?: "")}</p>")
                sb.append("<p><a href='/?action=bgp&go=1&asn=$asn'>&#9654; Обновить edges из BGP по AS$asn</a></p>")
            } else {
                sb.append("<p class=bad>ASN не определён (RIPEstat не ответил).</p>")
            }
        } else {
            sb.append("<p class=bad>не удалось получить edge IP (домен недоступен? VPN/DPI? опечатка?).</p>")
        }
        return html(sb.toString())
    }

    private fun doBgp(session: IHTTPSession): Response {
        val asn = sn(p(session, "asn")).toIntOrNull() ?: 57363
        if (p(session, "go") == "1" && !State.bgpRunning) {
            State.bgpReset()
            State.bgpRunning = true
            State.scope.launch {
                try { State.edges = Edges.fetchBgp(asn) }
                catch (e: Exception) { State.bgpLog("ошибка: ${e.message}") }
                finally { State.bgpRunning = false }
            }
        }
        val sb = StringBuilder()
        return if (State.bgpRunning) {
            sb.append("<meta http-equiv=\"refresh\" content=\"2;url=/?action=bgp\">")
            sb.append("<h3>Обновляю edges из BGP (AS$asn)… <span class=warn>(автообновление)</span></h3>")
            sb.append("<pre>").append(esc(tail(State.bgpLogText(), 8))).append("</pre>")
            html(sb.toString())
        } else {
            sb.append("<h3>edges обновлён из BGP ✓ &nbsp; <a href='/'>к форме</a></h3>")
            sb.append("<pre>").append(esc(tail(State.bgpLogText(), 8))).append("</pre>")
            sb.append("<p>сейчас в списке: <b>${State.edges.size}</b> IP</p>")
            html(sb.toString())
        }
    }

    private fun doUpload(session: IHTTPSession, files: Map<String, String>): Response {
        if (session.method != Method.POST)
            return html("<p class=bad>нужен POST.</p><a href='/'>назад</a>")
        val ips = LinkedHashSet<String>()
        files["file"]?.let { fp ->
            try { File(fp).readLines().forEach { val t = it.trim(); if (IP4.matches(t)) ips.add(t) } }
            catch (e: Exception) {}
        }
        (session.parameters["ips"]?.firstOrNull() ?: "").lines().forEach {
            val t = it.trim(); if (IP4.matches(t)) ips.add(t)
        }
        return if (ips.isNotEmpty()) {
            State.edges = ips.toList()
            html("<p class=good>Загружено IP: ${ips.size} — список обновлён.</p><a href='/'>к форме</a>")
        } else {
            html("<p class=bad>Валидных IP не найдено. Список не изменён.</p><a href='/'>назад</a>")
        }
    }

    private fun doHome(session: IHTTPSession): Response {
        val domain = p(session, "domain").ifEmpty { "q01jsec1fz.a.trbcdn.net" }
        val path = p(session, "path").ifEmpty { "/api/v1/events/app-a8f31c.js" }
        State.ensureEdges()
        val body = """
<h2>CDN Edge Ranker</h2>
<form action="/" method="get">
  <input type="hidden" name="action" value="run">
  <div>домен: <input name="domain" size="34" value="${esc(domain)}"></div>
  <div>путь: &nbsp; <input name="path" size="34" value="${esc(path)}"></div>
  <div>rounds <input name="rounds" size="3" value="10">
       conc <input name="conc" size="3" value="16">
       код <input name="ecode" size="3" value="400">
       заголовок <input name="mhdr" size="16" value="x-cdn-edge-cache"></div>
  <div>список:
    <select name="src">
      <option value="edges">полный список (${State.edges.size} IP, медленно)</option>
      <option value="ips_ok">быстрый — прошлые живые (${State.ipsOk.size} IP)</option>
    </select>
    <button type="submit">Запустить</button>
  </div>
</form>
<hr>
<form action="/" method="get">
  <input type="hidden" name="action" value="resolve">
  <div>определить бэкенд-ASN по домену: <input name="d" size="28" value="${esc(domain)}">
  <button type="submit">Определить ASN</button></div>
</form>
<form action="/" method="get">
  <input type="hidden" name="action" value="bgp">
  <input type="hidden" name="go" value="1">
  <div>обновить список из BGP: AS<input name="asn" size="7" value="57363">
  <button type="submit">Обновить из BGP</button>
  <span class=warn>(реальные префиксы ASN из RIPEstat)</span></div>
</form>
<form action="/?action=upload" method="post" enctype="multipart/form-data">
  <div>свой список IP (заменит текущий):</div>
  <div><input type="file" name="file" accept=".txt,.csv"></div>
  <div>или вставь IP (по одному в строке):</div>
  <div><textarea name="ips" rows="4" cols="30" placeholder="1.2.3.4&#10;5.6.7.8"></textarea></div>
  <div><button type="submit">Загрузить список</button></div>
</form>
<p><a href="/?action=status">Последний результат / статус →</a></p>
<p class=warn>Замер идёт с этого телефона — результат отражает его сеть. VPN на время замера выключи (в логе покажется твой внешний IP).</p>
"""
        return html(body)
    }

    private fun csv(): Response =
        newFixedLengthResponse(Response.Status.OK, "text/csv; charset=utf-8", buildCsv())

    // ---- helpers ---------------------------------------------------------

    private fun p(s: IHTTPSession, k: String): String = s.parameters[k]?.firstOrNull() ?: ""
    private fun sd(v: String) = v.filter { it.isLetterOrDigit() || it == '.' || it == '-' }
    private fun sp(v: String) = v.filter { it.isLetterOrDigit() || it in "._/~-" }
    private fun sn(v: String) = v.filter { it.isDigit() }
    private fun shd(v: String) = v.filter { it.isLetterOrDigit() || it == '-' }

    private fun esc(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    private fun fmt1(d: Double) = String.format("%.1f", d)

    private fun tail(text: String, n: Int): String {
        val lines = text.trimEnd('\n').lines()
        return if (lines.size <= n) lines.joinToString("\n")
        else lines.subList(lines.size - n, lines.size).joinToString("\n")
    }

    private fun vbanner(): String {
        val markers = listOf("ТЕСТ ИДЁТ С IP", "регион:", "провайдер:", "ASN:")
        val lines = State.progressText().lines().filter { l -> markers.any { l.contains(it) } }
        return if (lines.isEmpty()) "" else "<pre class=good>${esc(lines.joinToString("\n"))}</pre>"
    }

    private fun html(body: String, sort: Boolean = false): Response =
        newFixedLengthResponse(
            Response.Status.OK, "text/html; charset=utf-8",
            "<!doctype html><html><head><meta charset=utf-8>" +
                "<meta name=viewport content=\"width=device-width, initial-scale=1\">" +
                STYLE + (if (sort) SORTJS else "") + "</head><body>" + body + "</body></html>"
        )

    companion object {
        private const val STYLE = """<style>
body{font-family:system-ui,Arial;margin:1rem;background:#0e1116;color:#e6edf3}
input,select,button,textarea{font-size:1rem;padding:.4rem;margin:.15rem;background:#161b22;color:#e6edf3;border:1px solid #30363d;border-radius:6px}
button{background:#238636;border:0;cursor:pointer;font-weight:600}
table{border-collapse:collapse;width:100%;margin-top:1rem;font-size:.88rem}
th,td{border:1px solid #30363d;padding:.3rem .5rem;text-align:right}
th{cursor:pointer;position:sticky;top:0;background:#21262d;user-select:none}
th:hover{background:#30363d}
th:nth-child(2),td:nth-child(2){text-align:left}
tr:nth-child(even){background:#161b22}
.good{color:#3fb950}.warn{color:#d29922}.bad{color:#f85149}
pre{background:#161b22;padding:.6rem;border-radius:6px;overflow:auto;white-space:pre-wrap}
a{color:#58a6ff}h2,h3{margin:.4rem 0}hr{border-color:#30363d}
</style>"""

        private const val SORTJS = """<script>
function srt(t,n){var tb=document.getElementById(t),rows=Array.from(tb.tBodies[0].rows);
var asc=tb.getAttribute("data-c")==n&&tb.getAttribute("data-a")=="1"?false:true;
rows.sort(function(a,b){var x=a.cells[n].innerText,y=b.cells[n].innerText;
var nx=parseFloat(x),ny=parseFloat(y);
if(!isNaN(nx)&&!isNaN(ny)){return asc?nx-ny:ny-nx;}
return asc?x.localeCompare(y):y.localeCompare(x);});
rows.forEach(function(r){tb.tBodies[0].appendChild(r);});
tb.setAttribute("data-c",n);tb.setAttribute("data-a",asc?"1":"0");}
</script>"""
    }
}
