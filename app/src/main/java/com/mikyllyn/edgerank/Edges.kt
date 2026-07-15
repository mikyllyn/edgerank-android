package com.mikyllyn.edgerank

import okhttp3.Request
import org.json.JSONObject

object Edges {

    private const val MINLEN = 16

    // Fallback: CDNvideo announced ranges (mirrors gen-edges-asn.sh FALLBACK).
    private val FALLBACK_CIDRS = listOf(
        "46.42.184.0/21", "78.159.248.0/22", "81.9.16.0/20", "81.211.66.0/24",
        "81.222.124.0/22", "82.196.128.0/19", "91.231.232.0/21", "91.238.108.0/22",
        "91.240.168.0/21", "151.236.64.0/19", "185.31.114.0/24", "185.141.224.0/24",
        "194.76.124.0/22", "213.33.184.0/21", "216.152.144.0/24"
    )

    private fun ip2long(ip: String): Long {
        val p = ip.split(".")
        return (p[0].toLong() shl 24) or (p[1].toLong() shl 16) or
                (p[2].toLong() shl 8) or p[3].toLong()
    }

    private fun long2ip(v: Long): String =
        "${(v shr 24) and 255}.${(v shr 16) and 255}.${(v shr 8) and 255}.${v and 255}"

    /** Expand a CIDR to host IPs, skipping .0/.255 and prefixes shorter than /MINLEN. */
    fun expandCidr(cidr: String, out: MutableList<String>) {
        if (cidr.contains(":")) return
        val slash = cidr.indexOf('/')
        if (slash < 0) return
        val net = cidr.substring(0, slash)
        val plen = cidr.substring(slash + 1).toIntOrNull() ?: return
        if (plen < MINLEN || plen > 32) return
        if (!Regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$").matches(net)) return
        val base = ip2long(net)
        val size = 1L shl (32 - plen)
        val start = base and (0xFFFFFFFFL xor (size - 1))
        val end = start + size - 1
        var i = start
        while (i <= end) {
            val last = i and 255
            if (last != 0L && last != 255L) out.add(long2ip(i))
            i++
        }
    }

    fun fallbackExpanded(): List<String> {
        val out = ArrayList<String>()
        for (c in FALLBACK_CIDRS) expandCidr(c, out)
        return out.distinct()
    }

    /** Fetch real announced BGP prefixes for an ASN from RIPEstat, expand to IPs. */
    /** Fetch announced BGP prefixes for one or several ASNs (multi-CDN) and expand to IPs. */
    fun fetchBgp(asns: List<Int>): List<String> {
        val prefixes = ArrayList<String>()
        for (asn in asns) {
            State.bgpLog("Тяну префиксы AS$asn из RIPEstat…")
            var cnt = 0
            try {
                val body = Prober.apiClient.newCall(
                    Request.Builder()
                        .url("https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS$asn")
                        .build()
                ).execute().use { it.body?.string() ?: "" }
                val arr = JSONObject(body).optJSONObject("data")?.optJSONArray("prefixes")
                if (arr != null) {
                    for (i in 0 until arr.length()) {
                        val pfx = arr.getJSONObject(i).optString("prefix")
                        if (pfx.isNotEmpty() && !pfx.contains(":")) { prefixes.add(pfx); cnt++ }
                    }
                }
                State.bgpLog("  AS$asn: $cnt IPv4-префиксов")
            } catch (e: Exception) {
                State.bgpLog("  AS$asn: RIPEstat недоступен (${e.message})")
            }
        }

        val usePrefixes = if (prefixes.isEmpty()) {
            State.bgpLog("Ничего не получено — беру встроенный запасной список CDNvideo.")
            FALLBACK_CIDRS
        } else prefixes.distinct()

        State.bgpLog("Всего префиксов: ${usePrefixes.size}, разворачиваю…")
        val out = ArrayList<String>()
        for (c in usePrefixes) expandCidr(c, out)
        val result = out.distinct()
        State.bgpLog("готово: ${result.size} IP")
        return result
    }
}
