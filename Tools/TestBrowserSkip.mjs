import { execFileSync } from 'node:child_process';
import vm from 'node:vm';
const binary = process.argv[2];
let checks = 0;
const first = 'https://www.youtube.com/watch?v=alpha';
const second = 'https://www.youtube.com/watch?v=beta';
function run({next = true, expected = first, history, href = first, control, entries = [], referrer = '', player, selectors = {}, queue = [], links = [], selected, keyboard = false, traverseTo} = {}) {
  const source = execFileSync(binary, ['--script', next ? 'next' : 'previous', expected, ...(history ? [history] : [])], {encoding: 'utf8'});
  const actions = [];
  const location = {href, assign: url => actions.push(['navigate', url])};
  const document = {
    title: 'same title', referrer,
    querySelector: s => s === 'ytd-playlist-panel-video-renderer[selected]' ? selected : s.startsWith('.ytp-') ? control : undefined,
    querySelectorAll: s => s.startsWith('ytd-compact-autoplay') ? queue : s === 'a[href]' ? links : selectors[s] || [],
    getElementById: () => player,
    body: {dispatchEvent: event => {actions.push(['key', event.type, event.key, event.shiftKey]); return true;}},
  };
  const context = {URL, JSON, location, document, navigator: {mediaSession: {metadata: {title: 'track', artist: 'artist', album: 'album'}}},
    window: {navigation: {entries: () => entries, currentEntry: {index: 8}, traverseTo}},
    KeyboardEvent: keyboard ? function(type, options) {this.type = type; Object.assign(this, options);} : undefined,
    getComputedStyle: el => el.style || {display: 'block', visibility: 'visible'}};
  return {result: JSON.parse(vm.runInNewContext(source, context)), actions};
}
function button(href, extra = {}) {
  return {href, disabled: false, getAttribute: () => null, getClientRects: () => [1], click() {this.clicks = (this.clicks || 0) + 1;}, ...extra};
}
function check(name, pass) { checks++; if (!pass) throw new Error('FAIL: ' + name); console.log('PASS: ' + name); }
let control = button(second), value = run({control});
check('YouTube next clicks the native player without a full page reload', !value.actions.length && control.clicks === 1 && value.result.detail === 'native-control');
check('a dispatch is pending, never reported as already changed', value.result.status === 'sent' && value.result.before === 'youtube:alpha');
value = run({control: button(first)});
check('same-video links never trigger a navigation', value.actions.length === 0);
control = button(null, {style: {display: 'none', visibility: 'visible'}}); value = run({next: false, control});
check('hidden previous controls are not clicked', value.result.status === 'unavailable' && !control.clicks);
value = run({next: false, control, history: second});
check('app history works when the previous control is hidden', value.actions[0]?.[1] === second);
value = run({next: false, entries: [{index: 2, url: second}, {index: 7, url: 'https://example.com/'}]});
check('same-origin browser video history is usable', value.actions[0]?.[1] === second);
value = run({next: false, referrer: second});
check('a valid previous YouTube referrer is usable', value.actions[0]?.[1] === second);
value = run({next: false, referrer: 'https://example.com/private'});
check('previous never navigates to unrelated browsing history', value.result.status === 'unavailable' && value.actions.length === 0);
control = button(second); value = run({control, href: second});
check('stale video target does not click anything', value.result.status === 'stale' && !control.clicks && !value.actions.length);
value = run({href: 'https://example.com/', control});
check('reordered tab on another site is rejected', value.result.status === 'stale' && !value.actions.length);
let apiCalls = 0; value = run({player: {nextVideo() {apiCalls++;}}});
check('next player API is a fallback when no real link exists', apiCalls === 1 && value.result.status === 'sent');
const hidden = button(null, {style: {display: 'none', visibility: 'visible'}}), visible = button(null);
value = run({expected: 'https://music.youtube.com/watch?v=alpha', href: 'https://music.youtube.com/watch?v=alpha', selectors: {'.next-button': [hidden, visible]}});
check('other sites ignore hidden controls and click a visible one', !hidden.clicks && visible.clicks === 1 && value.result.status === 'sent');
const disabled = button(second, {getAttribute: () => 'true'}); value = run({next: false, control: disabled});
check('aria-disabled controls are never clicked', !disabled.clicks && value.result.status === 'unavailable');
value = run({next: false, history: 'https://youtube.com.evil.example/watch?v=beta'});
check('lookalike history domains cannot be navigated', value.result.status === 'unavailable' && !value.actions.length);
value = run({history: second, control: button('https://www.youtube.com/watch?v=other')});
check('next after returning reuses forward history off a playlist', value.actions[0]?.[1] === second);
let queueNext = button(second);value = run({queue: [button(first), button('https://example.com/'), queueNext]});
check('fullscreen queue uses a native link without reloading the page', queueNext.clicks === 1 && !value.actions.length);
let playlistNext = button(second);value = run({selected: {nextElementSibling: {querySelector: () => playlistNext, nextElementSibling: null}}});
check('playlist selected item advances with its own native link', playlistNext.clicks === 1 && !value.actions.length);
control = button(second, {style: {display: 'none', visibility: 'visible'}}); value = run({control});
check('a hidden fullscreen control can still supply a validated video URL', value.actions[0]?.[1] === second && !control.clicks);
value = run({keyboard: true});
check('missing fullscreen controls can dispatch Shift+N, with verification still pending', value.result.status === 'sent' && value.result.before === 'youtube:alpha' && value.actions[0]?.join() === 'key,keydown,N,true');
const forward = button(second);value = run({history: second, links: [forward]});
check('observed forward history reuses a matching native link', forward.clicks === 1 && !value.actions.length);
let traversal;value = run({next:false,history:second,entries:[{index:7,url:second,key:'known-video'}],traverseTo:key=>{traversal=key;}});
check('previous reuses a known browser history entry before loading a new page', traversal === 'known-video' && !value.actions.length);
console.log(`All ${checks} browser skip script checks passed`);

let seekChecks=0;
function checkSeek(name,pass){seekChecks++;check(name,pass);}
function media({paused=false,duration=300,pauseOnSeek=false}={}){
  let currentTime=20;const listeners=new Map();
  return {paused,duration,ended:false,plays:0,pauses:0,listeners,
    get currentTime(){return currentTime;},set currentTime(t){currentTime=t;if(pauseOnSeek)this.paused=true;},
    play(){this.paused=false;this.plays++;return Promise.resolve();},pause(){this.paused=true;this.pauses++;},
    addEventListener(name,fn){listeners.set(name,fn);},removeEventListener(name,fn){if(listeners.get(name)===fn)listeners.delete(name);},
    finish(){listeners.get('seeked')?.();},
  };
}
function seek({time=30.25,expected=first,href=first,v=media(),main,extra=[],player,context:existing}={}){
  const source=execFileSync(binary,['--seek',String(time),expected],{encoding:'utf8'});
  const timers=new Map();let id=0;
  const context=existing||{URL,JSON,Array,isFinite,location:{href},
    document:{getElementById:()=>player||(main?{querySelector:()=>main}:null),querySelectorAll:()=>[...extra,v]},
    setTimeout:fn=>{timers.set(++id,fn);return id;},clearTimeout:id=>timers.delete(id)};
  return {result:vm.runInNewContext(source,context),v,timers,context};
}
let seekValue=seek();
checkSeek('seeking keeps fractional seconds and playing state',seekValue.result==='ok'&&seekValue.v.currentTime===30.25&&!seekValue.v.paused);
seekValue.v.finish();
checkSeek('seek completion removes its listener and timeout',seekValue.v.listeners.size===0&&seekValue.timers.size===0);
let v=media({pauseOnSeek:true});seekValue=seek({v});v.finish();
checkSeek('a seek that pauses the media resumes the playing track',!v.paused&&v.plays===1);
v=media();seekValue=seek({v});v.paused=true;v.finish();
checkSeek('an asynchronous pause during seeking is restored once',!v.paused&&v.plays===1&&v.listeners.size===0);
v=media({paused:true});seekValue=seek({v});v.finish();
checkSeek('seeking an already paused track keeps it paused',v.paused&&v.plays===0);
v=media({paused:true});let apiCallsSeek=0;const player={querySelector:()=>v,seekTo(t,allow){apiCallsSeek++;v.currentTime=t;v.paused=false;},playVideo(){v.play();}};
seekValue=seek({v,player});v.finish();
checkSeek('YouTube seekTo is preferred and paused playback is preserved',apiCallsSeek===1&&v.paused&&v.pauses===1);
v=media({pauseOnSeek:true});const mainPlayer={querySelector:()=>v,seekTo(t){v.currentTime=t;},playVideo(){v.play();}};
seekValue=seek({v,player:mainPlayer});v.finish();
checkSeek('YouTube playback resumes through its player API',v.plays===1&&!v.paused);
v=media();const preview=media();seekValue=seek({v:preview,main:v});v.finish();
checkSeek('the main YouTube player is selected over a preview video',v.currentTime===30.25&&preview.currentTime===20);
v=media();const hiddenVideo=media({paused:true});seekValue=seek({v,extra:[hiddenVideo]});v.finish();
checkSeek('other sites seek the playing media rather than a hidden paused tag',v.currentTime===30.25&&hiddenVideo.currentTime===20);
v=media({duration:40});seekValue=seek({v,time:90});v.finish();
checkSeek('seeking is bounded by the actual media duration',v.currentTime===40);
v=media({duration:Infinity});seekValue=seek({v,time:90});v.finish();
checkSeek('live streams with a seekable position accept a finite target',v.currentTime===90);
seekValue=seek({href:second});
checkSeek('a stale YouTube tab is not seeked',seekValue.result==='stale'&&seekValue.v.currentTime===20);
seekValue=seek({href:'https://example.com/'});
checkSeek('reordered tabs on another site are not seeked',seekValue.result==='stale'&&seekValue.v.currentTime===20);
v=media();seekValue=seek({v});seek({v,context:seekValue.context,time:45});
checkSeek('repeated seeks retain at most one listener and timeout',v.listeners.size===1&&seekValue.timers.size===1&&v.currentTime===45);
for(const cleanup of seekValue.timers.values())cleanup();
checkSeek('a stalled seek releases its handler without starting a paused track',v.listeners.size===0&&v.plays===0);
console.log(`All ${seekChecks} playback seek checks passed`);
