import Foundation

/// Use the visible YouTube player rather than a preview/ad's first media tag.
enum BrowserPlaybackScript {
    static let mediaFunction = """
    function media(){var p=document.getElementById('movie_player');
    var main=p&&p.querySelector('video.html5-main-video');if(main)return main;
    var all=Array.from(document.querySelectorAll('video,audio'));
    return all.find(function(v){return !v.paused&&!v.ended;})||
      all.find(function(v){return v.duration>0;})||all[0]||null;}
    """

    static func seek(to time: TimeInterval, expectedURL: String) -> String {
        let options: [String: Any] = ["time": time.isFinite ? max(0, time) : 0, "expected": expectedURL]
        let data = try! JSONSerialization.data(withJSONObject: options, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        return """
        (function(){var o=\(json);\(mediaFunction)
        var actual=new URL(location.href),expected=new URL(o.expected);
        if(actual.hostname!==expected.hostname||
          (/^(www\\.)?(music\\.)?youtube\\.com$/.test(actual.hostname)&&actual.searchParams.get('v')!==expected.searchParams.get('v')))return 'stale';
        var v=media();if(!v)return 'unavailable';
        var p=document.getElementById('movie_player'),playing=!v.paused&&!v.ended;
        var target=isFinite(v.duration)?Math.min(o.time,Math.max(0,v.duration)):o.time;
        if(v.__funNotchSeekCleanup)v.__funNotchSeekCleanup();
        var timeout;function cleanup(){clearTimeout(timeout);v.removeEventListener('seeked',settled);
          if(v.__funNotchSeekCleanup===cleanup)delete v.__funNotchSeekCleanup;}
        function restore(){if(playing&&v.paused){
            if(p&&typeof p.playVideo==='function')p.playVideo();
            else {var promise=v.play();if(promise&&promise.catch)promise.catch(function(){});}
          }else if(!playing&&!v.paused)v.pause();}
        function settled(){cleanup();restore();}
        v.__funNotchSeekCleanup=cleanup;v.addEventListener('seeked',settled,{once:true});
        timeout=setTimeout(cleanup,3000);
        try{if(p&&typeof p.seekTo==='function')p.seekTo(target,true);else v.currentTime=target;
          restore();return 'ok';}catch(e){cleanup();return 'unavailable';}})()
        """
    }
}
