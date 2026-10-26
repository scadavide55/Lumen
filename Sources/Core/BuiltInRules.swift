import Foundation

// MARK: - Built-in rules

/// Offline rules that work out of the box: well-known third-party ad and tracking
/// hosts, a few tracking endpoints on first-party domains, and generic ad slots.
enum BuiltInRules {
    static let adHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
        "googletagservices.com", "2mdn.net", "admob.com", "adnxs.com", "adsrvr.org", "amazon-adsystem.com",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "outbrainimg.com", "revcontent.com",
        "mgid.com", "zergnet.com", "pubmatic.com", "rubiconproject.com", "openx.net", "casalemedia.com",
        "indexww.com", "sharethrough.com", "triplelift.com", "3lift.com", "yieldmo.com", "teads.tv",
        "smartadserver.com", "adform.net", "adformdsp.net", "bidswitch.net", "mathtag.com", "media.net",
        "contextweb.com", "sovrn.com", "lijit.com", "gumgum.com", "spotxchange.com", "spotx.tv",
        "springserve.com", "undertone.com", "advertising.com", "adtechus.com", "serving-sys.com",
        "flashtalking.com", "innovid.com", "adroll.com", "popads.net", "popcash.net", "propellerads.com",
        "adsterra.com", "exoclick.com", "juicyads.com", "trafficjunky.net", "adcash.com", "hilltopads.net",
        "zedo.com", "infolinks.com", "kargo.com", "33across.com", "emxdgt.com", "onetag-sys.com",
        "rhythmone.com", "1rx.io", "smaato.net", "inmobi.com", "adcolony.com", "chartboost.com",
        "vungle.com", "applovin.com", "unityads.unity3d.com", "ads.yahoo.com", "adtech.de", "zemanta.com",
        "yieldlab.net", "adition.com", "yieldlove.com", "adhese.com", "seedtag.com", "richaudience.com",
        "adskeeper.co.uk", "adskeeper.com", "buysellads.com", "carbonads.com", "carbonads.net",
        "ezoic.net", "ezojs.com", "mediavine.com", "adthrive.com", "pub.network", "adzerk.net",
        "servedbyadbutler.com", "adbutler.com", "lockerdome.com", "nativo.com", "ntv.io", "connatix.com",
        "primis.tech", "vidazoo.com", "aniview.com", "playwire.com", "venatusmedia.com", "adsafeprotected.com",
        "doubleverify.com", "moatads.com", "adsymptotic.com", "admanmedia.com", "ad.gt", "adlightning.com",
        "a-mo.net", "betweendigital.com", "e-planning.net", "smartclip.net", "stroeerdigitalmedia.de",
        "ads.linkedin.com", "ads.tiktok.com", "ads-api.tiktok.com", "ads-twitter.com", "ads.pinterest.com",
        "ads.reddit.com", "adsappier.com", "bounceexchange.com", "bouncex.net", "attn.tv",
    ]

    static let trackerHosts = [
        "google-analytics.com", "googletagmanager.com", "analytics.google.com", "app-measurement.com",
        "connect.facebook.net", "pixel.facebook.com", "analytics.tiktok.com", "analytics.twitter.com",
        "ct.pinterest.com", "bat.bing.com", "clarity.ms", "snap.licdn.com", "sc-static.net", "tr.snapchat.com",
        "scorecardresearch.com", "quantserve.com", "quantcount.com", "imrworldwide.com", "chartbeat.com",
        "chartbeat.net", "hotjar.com", "hotjar.io", "mixpanel.com", "segment.io", "cdn.segment.com",
        "api.segment.io", "api.amplitude.com", "api2.amplitude.com", "cdn.amplitude.com", "fullstory.com",
        "heapanalytics.com", "heap.io", "mouseflow.com", "crazyegg.com", "luckyorange.com", "luckyorange.net",
        "inspectlet.com", "clicktale.net", "contentsquare.net", "quantummetric.com", "kissmetrics.com",
        "appsflyer.com", "kochava.com", "bluekai.com", "krxd.net", "exelator.com", "demdex.net",
        "omtrdc.net", "2o7.net", "omniture.com", "everesttech.net", "rlcdn.com", "agkn.com",
        "crwdcntrl.net", "tapad.com", "liadm.com", "id5-sync.com", "turn.com", "rfihub.com", "eyeota.net",
        "permutive.com", "permutive.app", "cxense.com", "parsely.com", "gemius.pl", "xiti.com",
        "webtrekk.net", "statcounter.com", "histats.com", "addthis.com", "sharethis.com", "mc.yandex.ru",
        "top-fwz1.mail.ru", "counter.yadro.ru", "hm.baidu.com", "cnzz.com", "nr-data.net",
        "browser-intake-datadoghq.com", "akstat.io", "go-mpulse.net", "tealiumiq.com", "newrelic.com",
        "ml314.com", "zoominfo.com", "ws.zoominfo.com", "6sc.co", "bizible.com", "munchkin.marketo.net",
        "pardot.com", "hs-analytics.net", "hs-banner.com", "hubspot-analytics.com", "track.hubspot.com",
        "outbrain-analytics.com", "taboola-analytics.com", "branch.io", "adjust.com", "mparticle.com",
        "onesignal.com", "pushwoosh.com", "pushcrew.com", "webengage.com", "clevertap-prod.com",
        "smartlook.com", "logrocket.io", "lr-ingest.io", "posthog.com", "rudderstack.com",
    ]

    /// Tracking endpoints that live on domains which are otherwise needed.
    static let pathFilters = [
        #"^[^:]+://+([^:/]+\.)?facebook\.com/tr[/?]"#,
        #"^[^:]+://+([^:/]+\.)?google\.com/pagead/"#,
        #"^[^:]+://+([^:/]+\.)?google\.com/ads/"#,
        #"^[^:]+://+([^:/]+\.)?youtube\.com/pagead/"#,
        #"^[^:]+://+([^:/]+\.)?youtube\.com/api/stats/ads"#,
        #"^[^:]+://+([^:/]+\.)?linkedin\.com/px/"#,
        #"^[^:]+://+([^:/]+\.)?reddit\.com/rp\.gif"#,
        #"^[^:]+://+([^:/]+\.)?twitter\.com/i/adsct"#,
        #"^[^:]+://+([^:/]+\.)?amazon\.com/.*/uedata"#,
    ]

    static let selectors = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_iframe\"]", "[id^=\"div-gpt-ad\"]",
        "[id^=\"google_ads_\"]", "[data-google-query-id]", "[data-ad-slot]", "[data-ad-unit]",
        "[data-ad-client]", "amp-ad", "amp-embed[type=\"taboola\"]", ".GoogleActiveViewElement",
        ".ad-slot", ".ad-banner", ".adBanner", ".ad-container", ".ad-wrapper", ".ad-unit",
        ".advertisement", "[aria-label=\"Advertisement\"]", ".taboola", "[id^=\"taboola-\"]",
        ".trc_related_container", ".OUTBRAIN", ".ob-widget", "#carbonads", ".mgbox", "[id^=\"rcjsload\"]",
        ".zergnet-widget", "[id^=\"ezoic-pub-ad\"]", ".ezoic-ad", ".adthrive-ad", ".mv-ad-box",
    ]

    static var count: Int { adHosts.count + trackerHosts.count + pathFilters.count + selectors.count }

    static func hostFilter(_ host: String) -> String {
        "^[^:]+://+([^:/]+\\.)?" + host.replacingOccurrences(of: ".", with: "\\.") + "[/:]"
    }

    static func json() -> String {
        var rules: [[String: Any]] = (adHosts + trackerHosts).map { host in
            ["trigger": ["url-filter": hostFilter(host), "load-type": ["third-party"]],
             "action": ["type": "block"]]
        }
        rules += pathFilters.map { ["trigger": ["url-filter": $0], "action": ["type": "block"]] }
        rules += selectors.map { ["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": $0]] }
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }

    static let cookieJSON = #"[{"trigger":{"url-filter":".*","load-type":["third-party"]},"action":{"type":"block-cookies"}}]"#
}
