import Foundation

/// Prefer the site's native transport, keeping the page and buffered player
/// alive. A validated navigation is a fallback when no transport is available.
enum BrowserSkipScript {
    static let identityFunction = """
    function identity(){var u=new URL(location.href),h=u.hostname.replace(/^www\\./,'');
    if(h==='youtube.com'||h==='music.youtube.com'){var id=u.searchParams.get('v');if(id)return 'youtube:'+id;}
    var m=navigator.mediaSession&&navigator.mediaSession.metadata;
    return location.href+'|'+(m?m.title+'|'+m.artist+'|'+m.album:document.title);}
    """
    static var identity: String { "(function(){\(identityFunction)return identity();})()" }

    static func hasChanged(before: String, after: String?) -> Bool {
        guard let after, !after.isEmpty, !after.hasPrefix("error:"), before != after else { return false }
        if before.hasPrefix("youtube:") { return after.hasPrefix("youtube:") && after.count > 8 }
        guard let old = URL(string: String(before.split(separator: "|", maxSplits: 1)[0])),
              let new = URL(string: String(after.split(separator: "|", maxSplits: 1)[0])) else { return false }
        return old.scheme == new.scheme && old.host == new.host
    }

    static func command(next: Bool, expectedURL: String, historyURL: String?, selectors: [String]) -> String {
        let options: [String: Any] = ["next": next, "expected": expectedURL, "history": historyURL ?? "", "selectors": selectors]
        let data = try! JSONSerialization.data(withJSONObject: options, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        return """
        (function(){var o=\(json);\(identityFunction)
        var before=identity();function result(status,detail){return JSON.stringify({status:status,before:before,detail:detail||''});}
        var actual=new URL(location.href),expected=new URL(o.expected);
        if(actual.hostname!==expected.hostname)return result('stale');
        var yt=actual.hostname==='www.youtube.com'||actual.hostname==='youtube.com';
        if(yt&&actual.searchParams.get('v')!==expected.searchParams.get('v'))return result('stale');
        function usable(e){if(!e||e.disabled||e.getAttribute('aria-disabled')==='true')return false;
        var c=getComputedStyle(e);return c.display!=='none'&&c.visibility!=='hidden'&&e.getClientRects().length>0;}
        function videoURL(raw){try{var u=new URL(raw,location.href);if(u.protocol!=='https:'||u.username||u.password)return null;
        if((u.hostname!=='www.youtube.com'&&u.hostname!=='youtube.com')||u.pathname!=='/watch')return null;
        var id=u.searchParams.get('v');return id&&id!==actual.searchParams.get('v')?u.href:null;}catch(e){return null;}}
        function navigate(raw,link){var url=videoURL(raw);if(!url)return false;
          if(link&&usable(link)){link.click();return true;}
          var links=document.querySelectorAll('a[href]');
          for(var k=0;k<links.length;k++){if(usable(links[k])&&videoURL(links[k].href)===url){links[k].click();return true;}}
          var nav=window.navigation,entries=nav&&nav.entries?nav.entries():[];
          if(nav&&typeof nav.traverseTo==='function'){
            for(var k=entries.length-1;k>=0;k--){if(entries[k].key&&videoURL(entries[k].url)===url){
              var navigation=nav.traverseTo(entries[k].key);if(navigation&&navigation.finished)navigation.finished.catch(function(){});return true;}}
          }
          location.assign(url);return true;}
        if(yt){
          if(o.next&&!actual.searchParams.has('list')&&navigate(o.history))return result('sent');
          var control=document.querySelector(o.next?'.ytp-next-button':'.ytp-prev-button');
          var destination=control&&(control.href||control.getAttribute('href'));
          if(usable(control)&&(!destination||videoURL(destination))){control.click();return result('sent','native-control');}
          if(navigate(o.history))return result('sent');
          if(!o.next){
            var entries=window.navigation&&window.navigation.entries?window.navigation.entries():[];
            var index=window.navigation&&window.navigation.currentEntry?window.navigation.currentEntry.index:-1;
            for(var i=entries.length-1;i>=0;i--){if(entries[i].index<index&&navigate(entries[i].url))return result('sent');}
            if(navigate(document.referrer))return result('sent');
          }
          var player=document.getElementById('movie_player');
          if(o.next&&player&&typeof player.nextVideo==='function'){player.nextVideo();return result('sent','native-player');}
          if(control&&!control.disabled&&control.getAttribute('aria-disabled')!=='true'&&navigate(destination))return result('sent');
          if(o.next){
            var selected=document.querySelector('ytd-playlist-panel-video-renderer[selected]');
            var sibling=selected&&selected.nextElementSibling;
            while(sibling){var link=sibling.querySelector('a[href]');if(link&&navigate(link.href,link))return result('sent');sibling=sibling.nextElementSibling;}
            var queue=document.querySelectorAll('ytd-compact-autoplay-renderer a[href], ytd-watch-next-secondary-results-renderer a#thumbnail[href], #related a.yt-lockup-view-model__content-image[href], #secondary a.yt-lockup-view-model__content-image[href]');
            for(var i=0;i<queue.length;i++){if(navigate(queue[i].href,queue[i]))return result('sent');}
            if(typeof KeyboardEvent==='function'&&document.body){
              document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'N',code:'KeyN',keyCode:78,which:78,shiftKey:true,bubbles:true,cancelable:true}));
              document.body.dispatchEvent(new KeyboardEvent('keyup',{key:'N',code:'KeyN',keyCode:78,which:78,shiftKey:true,bubbles:true,cancelable:true}));
              return result('sent','keyboard-next');
            }
          }
          return result('unavailable','control='+!!control+',player='+!!player+',nextAPI='+(player?typeof player.nextVideo:'none')+',queue='+(typeof queue!=='undefined'?queue.length:0));
        }
        for(var i=0;i<o.selectors.length;i++){
          var controls=document.querySelectorAll(o.selectors[i]);
          for(var j=0;j<controls.length;j++){if(usable(controls[j])){controls[j].click();return result('sent');}}
        }
        return result('unavailable');})()
        """
    }
}

/// At most 40 observed videos per tab, without retaining page contents.
struct BrowserVideoHistory {
    private(set) var urls: [String] = []
    private(set) var index = -1
    private var target: Int?
    static func videoID(_ raw: String) -> String? {
        guard let u = URLComponents(string: raw), u.scheme == "https",
              ["youtube.com", "www.youtube.com"].contains(u.host), u.path == "/watch",
              let id = u.queryItems?.first(where: { $0.name == "v" })?.value, !id.isEmpty else { return nil }
        return id
    }
    mutating func record(_ url: String) {
        guard let id = Self.videoID(url) else { return }
        if let target, urls.indices.contains(target), Self.videoID(urls[target]) == id {
            index = target; self.target = nil; return
        }
        if urls.indices.contains(index), Self.videoID(urls[index]) == id { return }
        target = nil
        urls = Array(urls.prefix(index + 1)); urls.append(url)
        if urls.count > 40 { urls.removeFirst(urls.count - 40) }
        index = urls.count - 1
    }
    mutating func candidate(next: Bool) -> String? {
        let candidate = index + (next ? 1 : -1)
        guard urls.indices.contains(candidate) else { target = nil; return nil }
        target = candidate; return urls[candidate]
    }
    mutating func cancel() { target = nil }
}
