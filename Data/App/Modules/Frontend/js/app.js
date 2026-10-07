const $=id=>document.getElementById(id);
const enc=s=>btoa(unescape(encodeURIComponent(s)));
const dec=s=>JSON.parse(decodeURIComponent(escape(atob(s))));
const fmt=(v,n=2)=>Number.isFinite(Number(v))?Number(v).toFixed(n):'—';
function timeDeltaView(v,approx=false){
  if(v==null||v==='')return{state:'neutral',text:'—',marker:'—',direction:'当前没有可靠的可比时间'};
  const n=Number(v);if(!Number.isFinite(n))return{state:'neutral',text:'—',marker:'—',direction:'当前没有可靠的可比时间'};
  const mag=Math.abs(n).toFixed(3),prefix=approx?'≈':'';
  if(n>0)return{state:'loss',text:`${prefix}慢 ${mag}s`,marker:`${prefix}慢 ${mag}`,direction:`A 当前圈比 B 对比圈慢 ${mag}s`};
  if(n<0)return{state:'gain',text:`${prefix}快 ${mag}s`,marker:`${prefix}快 ${mag}`,direction:`A 当前圈比 B 对比圈快 ${mag}s`};
  return{state:'neutral',text:'持平 0.000s',marker:'持平 0.000',direction:'A 当前圈与 B 对比圈用时完全相同'};
}
function recoveryGainView(v){
  if(v==null||v==='')return{state:'neutral',text:'—'};
  const n=Number(v);if(!Number.isFinite(n))return{state:'neutral',text:'—'};
  const mag=Math.abs(n).toFixed(3);
  if(n>0)return{state:'gain',text:`A 追回 ${mag}s`};
  if(n<0)return{state:'loss',text:`A 损失 ${mag}s`};
  return{state:'neutral',text:'持平 0.000s'};
}
function identitySummary(file,lap,side){
  const label=side==='reference'?(isInternalStreamCompare()?'联网低频影子':compactReplayLabel(recordFor(file))):compactReplayLabel(recordFor(file));
  return `${side==='reference'?'对比':'当前'} · 圈${lap||'—'}${label?` · ${label}`:''}`;
}

let records=[],currentFile='',analysis=null,telemetry=null,stream=null,mapMeta=null,mapImage=null;
let currentLap='',compareFile='',compareLap='',compareInternalStreamId='',compareAnalysis=null,compareTelemetry=null,compareStream=null,compareMapMeta=null,compareMapImage=null;
let sectors=[],selectedSector=null,hoverSector=null,routeMode='recovery';
let customPath={subjectStartIdx:null,subjectEndIdx:null,referenceStartIdx:null,referenceEndIdx:null,dragHandle:null};
let borrowedMapMeta=null,borrowedMapImage=null,borrowedMapSource='';
let serverComparison=null,comparisonRequestKey='';
let view={zoom:1,panX:0,panY:0,drag:false,moved:false,x:0,y:0};
let viewModel=null,viewKey='',viewRevision=0,analysisRevision=0;
let inspectorPos={x:10,y:10},inspectorDrag=null,inspectorUserMoved=false,inspectorCollapsed=false; // product default: expanded on every frontend start
let replayRailCollapsed=false;
let systemStatus=null,bootstrapPollTaskId='',bootstrapPollPromise=null;

function fitMapViewportHeight(){
  const wrap=$('mapWrap');if(!wrap)return false;
  const note=$('mapNote'),top=Number(wrap.getBoundingClientRect?.().top)||0,noteH=Number(note?.getBoundingClientRect?.().height)||0;
  const viewport=Number(window.innerHeight)||Number(document.documentElement?.clientHeight)||900;
  const next=Math.max(120,Math.floor(viewport-top-noteH-8)),px=next+'px';
  if(wrap.style.height===px)return false;wrap.style.height=px;return true;
}
function clampInspectorPosition(){
  const panel=$('inspectorPanel'),wrap=$('mapWrap');if(!panel||!wrap)return;
  const wr=wrap.getBoundingClientRect(),pr=panel.getBoundingClientRect(),pad=8;
  const maxX=Math.max(pad,wr.width-pr.width-pad),maxY=Math.max(pad,wr.height-pr.height-pad);
  if(!inspectorUserMoved){inspectorPos.x=10;inspectorPos.y=10}
  inspectorPos.x=Math.min(maxX,Math.max(pad,Number(inspectorPos.x)||pad));
  inspectorPos.y=Math.min(maxY,Math.max(pad,Number(inspectorPos.y)||pad));
  panel.style.left=inspectorPos.x+'px';panel.style.top=inspectorPos.y+'px';
}
function setInspectorCollapsed(v){
  inspectorCollapsed=!!v;const panel=$('inspectorPanel'),btn=$('inspectorToggle');if(!panel||!btn)return;
  panel.classList.toggle('collapsed',inspectorCollapsed);btn.textContent=inspectorCollapsed?'+':'−';btn.title=inspectorCollapsed?'展开当前区段':'收起当前区段';btn.setAttribute?.('aria-label',btn.title);
  setTimeout(()=>{clampInspectorPosition();if(analysis)redrawCanvas()},0);
}
function setReplayRailCollapsed(v){
  replayRailCollapsed=!!v;const shell=$('shell'),btn=$('sideToggle');if(!shell||!btn)return;
  shell.classList.toggle('sideCollapsed',replayRailCollapsed);btn.textContent=replayRailCollapsed?'›':'‹';btn.title=replayRailCollapsed?'展开录像列表':'收起录像列表';btn.setAttribute?.('aria-label',btn.title);
  setTimeout(()=>{fitMapViewportHeight();clampInspectorPosition();if(analysis)redrawCanvas()},0);
}
function screenOverlayRects(canvas){
  const out=[],cr=canvas?.getBoundingClientRect?.();if(!cr)return out;
  for(const el of [$('inspectorPanel')]){
    if(!el||el.classList?.contains?.('hidden'))continue;const r=el.getBoundingClientRect?.();if(!r)continue;
    out.push({x:r.left-cr.left,y:r.top-cr.top,w:r.width,h:r.height});
  }
  return out;
}

const analysisCache=new Map(),telemetryCache=new Map(),mapCache=new Map(),imageCache=new Map();

function err(m){const e=$('error');e.textContent=String(m||'未知错误');e.classList.remove('hidden');setTimeout(()=>e.classList.add('hidden'),8000)}
async function json(url,opt){const r=await fetch(url,opt);const t=await r.text();if(!r.ok)throw new Error(t||r.statusText);return t?JSON.parse(t):null}
async function post(url,obj){return json(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(obj||{})})}
function labelOf(r){return r?.display_name||r?.replay||r?.file||'录像'}
function fileBaseName(v){return String(v||'').split(/[\\/]/).pop()||''}
function withoutSav(v){return String(v||'').replace(/\.sav$/i,'')}
function escapeRegExp(v){return String(v||'').replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}
function compactReplayText(text,mapName){
  let raw=withoutSav(fileBaseName(text)).trim();if(!raw)return'';
  const map=String(mapName||'').trim();if(!map||map==='赛道未识别'||map==='赛道身份待确认'||map==='未知地图')return raw;
  const rx=new RegExp('^'+escapeRegExp(map)+'(?:[\\s._·•—–-]+|$)','i');
  const cut=raw.replace(rx,'').trim();return cut||raw;
}
function compactReplayLabel(r){return compactReplayText(labelOf(r),r?.map)}
function compactReplaySource(r){return compactReplayText(r?.replay||r?.file||'',r?.map)}
function recordDurationText(r){const local=(r?.streams||[]).find(s=>s.role==='local_high_frequency')||(r?.streams||[])[0]||{};return local.duration_s==null?'—':fmt(local.duration_s,2)+'s'}
function localStream(t){return t?.streams?.find(s=>s.role==='local_high_frequency')||t?.streams?.[0]||null}
function networkStreams(t){return (t?.streams||[]).filter(s=>s.role==='network_low_frequency')}
function isInternalStreamCompare(){return compareFile===currentFile&&!!compareInternalStreamId}
function isSameReplayLapCompare(){return compareFile===currentFile&&!compareInternalStreamId}
function referenceStream(){return isInternalStreamCompare()?compareStream:(compareFile===currentFile?stream:compareStream)}
function compareTargetKeyForStream(s){return `__stream__:${String(s?.id||s?.stream_id||'')}`}
function streamIdOf(s){return String(s?.id||s?.stream_id||'')}
function setCompareControlEnabled(enabled){const a=$('compareReplay'),b=$('compareLap');if(a){a.disabled=!enabled;const box=a.closest('.lapPick')||a.parentElement;if(box){box.style.opacity=enabled?'1':'0.38';box.style.pointerEvents=enabled?'':'none'}}if(b){const box=b.closest('.lapPick')||b.parentElement;if(box)box.style.opacity=enabled?'1':'0.38'}}
function recordFor(file){return records.find(r=>r.file===file)||null}
function resourceIdOf(a){const n=Number(a?.resource_map_id??a?.map_id);return Number.isFinite(n)&&n>0?n:null}
function gameIdOf(x){const n=Number(x?.game_map_id);return Number.isFinite(n)&&n>0?n:null}
function mapNameKey(r){
  const raw=String(r?.map||'').trim();
  if(!raw||raw==='赛道未识别'||raw==='赛道身份待确认'||raw==='未知地图')return'';
  return raw.toLowerCase().replace(/\s+/g,'');
}
function comparisonKey(r){
  if(!r)return'';
  if(r.course_key)return String(r.course_key);
  const gid=gameIdOf(r);if(gid)return`game:${gid}`;
  const name=mapNameKey(r);return name?`name:${name}`:'';
}
function sameMapCompatible(a,b){
  if(!a||!b)return false;
  const ac=String(a.course_key||''),bc=String(b.course_key||'');
  if(ac&&bc&&ac===bc)return true;
  const ag=gameIdOf(a),bg=gameIdOf(b);if(ag&&bg&&ag===bg)return true;
  const an=mapNameKey(a),bn=mapNameKey(b);return !!an&&!!bn&&an===bn;
}
function comparisonBasis(a,b){
  if(!a||!b)return'';
  const ac=String(a.course_key||''),bc=String(b.course_key||'');if(ac&&bc&&ac===bc)return ac;
  const ag=gameIdOf(a),bg=gameIdOf(b);if(ag&&bg&&ag===bg)return`Game ${ag}`;
  const an=mapNameKey(a),bn=mapNameKey(b);if(an&&bn&&an===bn)return`同名地图 · ${a.map}`;
  return'';
}
async function loadAnalysis(f){if(analysisCache.has(f))return analysisCache.get(f);const j=await json('/api/analysis?file='+encodeURIComponent(f)+'&x='+Date.now());analysisCache.set(f,j);return j}
async function loadTelemetry(f){if(telemetryCache.has(f))return telemetryCache.get(f);const j=await json('/api/telemetry?file='+encodeURIComponent(f)+'&x='+Date.now());telemetryCache.set(f,j);return j}
// The official basemap is only used when the metadata really is a native map product. A metadata
// document that does not declare the native-map contract, an official source and a usable world
// transform is refused, so an unexpected payload can never be drawn as a track.
function nativeMapContractOk(m){return !!m&&m.contract==='native_map_v1'&&m.official_source===true&&m.render_transform!=null&&Number(m.render_transform.scale)>0&&!!m.vector_minimap}
async function loadMap(id){if(id==null)return null;if(mapCache.has(id))return mapCache.get(id);try{const j=await json('/api/map-meta?map_id='+encodeURIComponent(id)+'&x='+Date.now());if(!nativeMapContractOk(j))return null;mapCache.set(id,j);return j}catch{return null}}
async function img(path){if(!path)return null;if(imageCache.has(path))return imageCache.get(path);const im=new Image();const p=new Promise((ok,no)=>{im.onload=()=>ok(im);im.onerror=()=>no(new Error('地图 SVG 加载失败'))});im.src='/asset?path='+encodeURIComponent(path)+'&x='+Date.now();await p;imageCache.set(path,im);return im}
async function loadVisualMap(a){
  const rid=resourceIdOf(a);if(!rid||a?.native_map?.status!=='ready')return{meta:null,image:null};
  const meta=await loadMap(rid);if(!meta)return{meta:null,image:null};
  try{return{meta,image:await img(a.native_map?.vector_minimap)}}catch{return{meta,image:null}}
}
async function loadUniqueSameNameVisual(record){
  const key=mapNameKey(record);if(!key)return{meta:null,image:null,source:''};
  const donors=records.filter(r=>r.file!==record.file&&mapNameKey(r)===key&&r.native_map_status==='ready'&&Number(r.resource_map_id)>0);
  const ids=[...new Set(donors.map(r=>Number(r.resource_map_id)).filter(Number.isFinite))];
  if(ids.length!==1)return{meta:null,image:null,source:''};
  const donor=donors.find(r=>Number(r.resource_map_id)===ids[0]);if(!donor)return{meta:null,image:null,source:''};
  try{const a=await loadAnalysis(donor.file),v=await loadVisualMap(a);return{...v,source:`same-name:${donor.file}`}}catch{return{meta:null,image:null,source:''}}
}

async function loadList(keep=''){
  records=await json('/api/analyses?x='+Date.now());
  $('count').textContent=records.length;
  renderList();
  const target=keep&&records.some(r=>r.file===keep)?keep:(records[0]?.file||'');
  if(target)await openRecord(target);else{$('content').classList.add('hidden');$('empty').classList.remove('hidden')}
}
function renderList(){
  const q=$('search').value.trim().toLowerCase(),box=$('list');box.innerHTML='';
  for(const r of records){
    const local=(r.streams||[]).find(s=>s.role==='local_high_frequency')||(r.streams||[])[0]||{};
    const text=(labelOf(r)+' '+(r.map||'')+' '+(r.replay||'')).toLowerCase();if(q&&!text.includes(q))continue;
    const d=document.createElement('div');d.className='item'+(r.file===currentFile?' active':'');
    d.innerHTML='<div class="itemRow"><div class="itemName"></div><button class="miniBtn rename" title="重命名">✎</button><button class="miniBtn del" title="删除分析">×</button></div><div class="itemMeta"></div><div class="itemFile"></div><div class="itemAlerts"></div>';
    const shortName=compactReplayLabel(r),sourceShort=compactReplaySource(r);
    d.querySelector('.itemName').textContent=shortName||'录像';d.querySelector('.itemName').title=labelOf(r);
    const gid=gameIdOf(r),mapName=r.map||'赛道未识别';
    d.querySelector('.itemMeta').textContent=mapName;
    d.querySelector('.itemFile').textContent=`${gid?'Game '+gid+' · ':''}${local.duration_s==null?'—':fmt(local.duration_s,2)+'s'}${r.display_name&&sourceShort&&sourceShort!==shortName?' · '+sourceShort:''}`;
    d.querySelector('.itemFile').title=r.replay||r.file||'';
    const ab=d.querySelector('.itemAlerts');
    if(r.native_map_status!=='ready'){const s=document.createElement('span');s.className='alertBadge';s.textContent=gid?'⚠ 官方底图待确认':'⚠ 赛道身份待确认';ab.appendChild(s)}
    d.onclick=()=>openRecord(r.file);
    d.querySelector('.rename').onclick=async e=>{e.stopPropagation();const n=prompt('录像显示名称',labelOf(r));if(n==null)return;await post('/api/rename',{file_b64:enc(r.file),display_name_b64:enc(n)});await loadList(r.file)};
    d.querySelector('.del').onclick=async e=>{e.stopPropagation();if(!confirm('删除这份分析结果？原始录像会保留。'))return;await post('/api/delete-analysis',{file_b64:enc(r.file)});analysisCache.delete(r.file);telemetryCache.delete(r.file);if(currentFile===r.file)currentFile='';await loadList()};
    box.appendChild(d);
  }
}

function fastestLap(s){const laps=(s?.laps||[]).filter(l=>Number.isFinite(Number(l.duration_s)));if(!laps.length)return'';return String(laps.reduce((a,b)=>Number(a.duration_s)<=Number(b.duration_s)?a:b).lap)}
function firstLap(s){const laps=s?.laps||[],one=laps.find(l=>Number(l.lap)===1);const l=one||laps[0];return l?String(l.lap):''}
function localEpisodeStream(a){const xs=a?.driving_episodes?.streams||[];return xs.find(x=>x.role==='local_high_frequency')||(xs.length===1?xs[0]:null)}
// Stream ownership is resolved by EXACT identity first. A role is only a fallback when exactly one
// candidate carries it, because a replay may hold several network_low_frequency shadows: guessing
// "the first same-role stream" would silently attach another car's Drift/segment data to this one.
function streamByRoleIfUnique(list,role){
  if(!role)return null;
  const cand=(list||[]).filter(x=>String(x?.role||'')===role);
  return cand.length===1?cand[0]:null;
}
function episodeStreamFor(a,sourceStream=null){
  const xs=a?.driving_episodes?.streams||[];if(!xs.length)return null;
  if(!sourceStream)return localEpisodeStream(a);
  const id=streamIdOf(sourceStream);
  if(id){const hit=xs.find(x=>String(x?.id||'')===id);if(hit)return hit}
  return streamByRoleIfUnique(xs,String(sourceStream?.role||''))||null;
}
const DRIFT_SEGMENT_MERGE_GAP_S=.15;
const EXIT_SMALL_BOOST_WINDOW_S=2.0;
// The automatic segment list is NOT re-derived here. It is the analyzer's published contract
// (analysis.segment_analysis, contract native_analysis_segments_v1): native Drift start ->
// native recovery end, 150 ms logical-Drift merge, lap ownership by the first Drift start and a
// hard cut at the next independent Drift. The browser maps it onto world XY for drawing only.
//
// NORMALIZED UI SEGMENT CONTRACT. Every automatic segment is carried as ONE object shape through
// every stage of the UI, and it keeps the published native fields verbatim. The previous code
// converted a published segment into a "drift definition" that dropped `time` and the server
// fields, and the recovery stage then read `d.time.start_t` from an object that no longer had it
// (the field runtime error) while also silently falling back to browser recovery inference even
// though the analyzer had already published the authoritative recovery end.
function serverSegmentSource(a,sourceStream){
  const sa=a?.segment_analysis;if(!sa||sa.contract!=='native_analysis_segments_v1')return null;
  const xs=sa.streams||[];if(!xs.length)return null;
  if(!sourceStream){return xs.find(x=>String(x?.role||'')==='local_high_frequency')||(xs.length===1?xs[0]:null)}
  const id=streamIdOf(sourceStream);
  if(id){const hit=xs.find(x=>String(x?.id||'')===id);if(hit)return hit}
  return streamByRoleIfUnique(xs,String(sourceStream?.role||''));
}
// Raw published segment list of one lap (or null when the contract is absent).
function serverSegmentsForLap(a,lapNo,sourceStream){
  const src=serverSegmentSource(a,sourceStream);if(!src)return null;
  const lap=(src.laps||[]).find(l=>String(l.lap)===String(lapNo));if(!lap)return null;
  return (lap.segments||[]);
}
function uiSegmentFromServer(sg,ordinal){
  const startT=Number(sg.start_t),driftEndT=Number(sg.drift_end_t);
  if(!Number.isFinite(startT)||!Number.isFinite(driftEndT)||driftEndT<=startT)return null;
  const recRaw=Number(sg.recovery_end_t);
  const recoveryEndT=Number.isFinite(recRaw)?recRaw:driftEndT;
  return {server:true,serverSegmentIndex:Number(sg.segment_index),lapOwner:(sg.lap_owner==null?null:Number(sg.lap_owner)),
    driftCount:Number(sg.drift_count)||0,serverRecoveryAvailable:!!sg.recovery_available,
    serverRecoveryReason:String(sg.recovery_stop_reason||''),serverCrossesLap:!!sg.crosses_lap_boundary,
    serverNextDriftStartT:(Number.isFinite(Number(sg.next_drift_start_t))?Number(sg.next_drift_start_t):null),
    serverRecoveryEndT:recoveryEndT,startT,driftEndT,recoveryEndT,
    driftIntervals:(sg.drift_intervals||[]).map(iv=>({start_t:Number(iv.start_t),end_t:Number(iv.end_t)})),
    id:'L'+String(sg.lap_owner==null?'':sg.lap_owner)+'-S'+String(sg.segment_index),
    merged_episode_ids:(sg.episode_ids||[]).map(String),
    time:{start_t:startT,end_t:driftEndT,duration_s:(Number(sg.drift_duration_s)||Math.max(0,driftEndT-startT))}};
}
function uiSegmentFromMerge(ep,ids,startT,endT,driftCount){
  return {server:false,serverSegmentIndex:null,lapOwner:(ep&&ep.lap!=null?Number(ep.lap):null),driftCount:driftCount,
    serverRecoveryAvailable:null,serverRecoveryReason:'',serverCrossesLap:false,serverNextDriftStartT:null,
    serverRecoveryEndT:null,startT,driftEndT:endT,recoveryEndT:null,driftIntervals:[],
    id:String((ids||[]).join('+')||''),merged_episode_ids:(ids||[]).map(String),
    time:{start_t:startT,end_t:endT,duration_s:Math.max(0,endT-startT)}};
}
function driftEpisodesForLap(a,lapNo,sourceStream=null){const es=episodeStreamFor(a,sourceStream),lap=(es?.laps||[]).find(l=>String(l.lap)===String(lapNo));return (lap?.episodes||[]).filter(ep=>Number.isFinite(Number(ep?.time?.start_t))&&Number.isFinite(Number(ep?.time?.end_t))&&Number(ep.time.end_t)>Number(ep.time.start_t)).sort((x,y)=>Number(x.time.start_t)-Number(y.time.start_t))}
// Normalized segment list for one lap: the published contract when the analyzer published one,
// otherwise the in-browser 0.15 s merge of the logical native Drift episodes (compatibility path
// for an analysis written before the contract existed, or for a side that has no contract).
function driftSegmentsForLap(a,lapNo,sourceStream=null){
  const published=serverSegmentsForLap(a,lapNo,sourceStream);
  if(published&&published.length){
    const out=[];
    for(const sg of published){const seg=uiSegmentFromServer(sg,out.length+1);if(seg)out.push(seg)}
    if(out.length)return out;
  }
  const eps=driftEpisodesForLap(a,lapNo,sourceStream);if(!eps.length)return[];
  const out=[];
  for(const ep of eps){
    const st=Number(ep.time.start_t),et=Number(ep.time.end_t);
    if(!out.length){out.push(uiSegmentFromMerge(ep,[String(ep.id||'')],st,et,1));continue}
    const cur=out[out.length-1],gap=st-Number(cur.driftEndT);
    if(gap<DRIFT_SEGMENT_MERGE_GAP_S){
      cur.merged_episode_ids.push(String(ep.id||''));cur.driftCount=(Number(cur.driftCount)||1)+1;
      cur.driftEndT=Math.max(Number(cur.driftEndT),et);cur.time.end_t=cur.driftEndT;cur.time.duration_s=cur.driftEndT-cur.startT;
      cur.id=cur.merged_episode_ids.filter(Boolean).join('+')||cur.id;continue;
    }
    out.push(uiSegmentFromMerge(ep,[String(ep.id||'')],st,et,1));
  }
  return out;
}
function driftTailEndT(a,lapNo,sourceStream=null){const xs=driftSegmentsForLap(a,lapNo,sourceStream);return xs.length?Math.max(...xs.map(ep=>Number(ep.time.end_t)).filter(Number.isFinite)):null}
function allDriftEpisodes(a,sourceStream=null){const es=episodeStreamFor(a,sourceStream),out=[];for(const l of es?.laps||[])for(const ep of l?.episodes||[]){const st=Number(ep?.time?.start_t),et=Number(ep?.time?.end_t);if(Number.isFinite(st)&&Number.isFinite(et)&&et>st)out.push({start_t:st,end_t:et})}return out.sort((x,y)=>x.start_t-y.start_t)}
function nextDriftStartAfter(a,t,sourceStream=null){for(const ep of allDriftEpisodes(a,sourceStream))if(ep.start_t>Number(t)+1e-4)return ep.start_t;return null}
function routeViewEndT(a,s,lapNo){const tail=driftTailEndT(a,lapNo,s);if(routeMode!=='recovery')return tail;const lap=(s?.laps||[]).find(l=>String(l.lap)===String(lapNo));if(!lap)return tail;const base=Math.max(Number(lap.end_t),Number.isFinite(Number(tail))?Number(tail):Number(lap.end_t));const last=Number((s?.preview||[]).at(-1)?.t);return Number.isFinite(last)?Math.min(last,base+EXIT_SMALL_BOOST_WINDOW_S):base+EXIT_SMALL_BOOST_WINDOW_S}
function lapView(s,lapNo,extendEndT=null){
  if(!s||!lapNo)return null;const lap=(s.laps||[]).find(l=>String(l.lap)===String(lapNo));if(!lap)return null;
  const t0=Number(lap.start_t),lapEnd=Number(lap.end_t),tail=Number(extendEndT),t1=Number.isFinite(tail)?Math.max(lapEnd,tail):lapEnd,raw=(s.preview||[]).filter(p=>Number(p.t)>=t0-.02&&Number(p.t)<=t1+.02);
  const pts=raw.map(p=>({...p,source_t:Number(p.t),t:Number(p.t)-t0,x:Number(p.x),y:Number(p.y)})).filter(p=>Number.isFinite(p.x)&&Number.isFinite(p.y)&&Number.isFinite(p.t));
  return {lap:Number(lap.lap),duration_s:Number(lap.duration_s),points:pts,sample_hz:Number(s.sample_hz)||null,lap_end_t:lapEnd,view_end_t:t1};
}
function dist(a,b){return Math.hypot(Number(b.x)-Number(a.x),Number(b.y)-Number(a.y))}
function buildTrack(v){
  if(!v?.points?.length)return null;
  // Keep every ordered run in the selected lap. `break_before` means a transport/preview
  // discontinuity, not that the rest of the lap should be discarded. The old UI kept
  // only the longest run, which is why maps such as 一梦青花 showed only half a lap.
  const pts=v.points.slice();if(pts.length<8)return null;
  const cum=[0],runIds=[0];let runId=0;
  for(let i=1;i<pts.length;i++){
    const isBreak=!!pts[i].break_before;
    if(isBreak)runId++;
    // Do not invent distance across a discontinuity, but keep progress monotonic.
    cum.push(cum[i-1]+(isBreak?0:dist(pts[i-1],pts[i])));
    runIds.push(runId);
  }
  return {pts,cum,runIds,total:cum[cum.length-1],duration_s:v.duration_s,lap:v.lap};
}
function lowerBound(a,x){let lo=0,hi=a.length-1;while(lo<hi){const m=(lo+hi)>>1;if(a[m]<x)lo=m+1;else hi=m}return lo}
function pointAt(track,s){
  if(!track)return null;s=Math.max(0,Math.min(track.total,s));const i=lowerBound(track.cum,s);if(i<=0)return {...track.pts[0],s};const a=track.pts[i-1],b=track.pts[i],sa=track.cum[i-1],sb=track.cum[i],u=sb>sa?(s-sa)/(sb-sa):0;
  return {x:a.x+(b.x-a.x)*u,y:a.y+(b.y-a.y)*u,t:a.t+(b.t-a.t)*u,s};
}
function angleDiff(a,b){let d=b-a;while(d>Math.PI)d-=Math.PI*2;while(d<-Math.PI)d+=Math.PI*2;return d}
function quantile(a,q){if(!a.length)return 0;const b=[...a].sort((x,y)=>x-y),i=Math.max(0,Math.min(b.length-1,Math.round((b.length-1)*q)));return b[i]}
function nearestSourceIndex(track,t){
  if(!track?.pts?.length)return null;let lo=0,hi=track.pts.length-1;
  while(lo<hi){const m=(lo+hi)>>1;if(Number(track.pts[m].source_t)<t)lo=m+1;else hi=m}
  if(lo>0&&Math.abs(Number(track.pts[lo-1].source_t)-t)<=Math.abs(Number(track.pts[lo].source_t)-t))return lo-1;return lo;
}
function driftSectorDefinition(track,a,lapNo,sourceStream=null){
  if(!track)return[];const segs=driftSegmentsForLap(a,lapNo,sourceStream),out=[];
  for(const seg of segs){
    let si=nearestSourceIndex(track,Number(seg.startT)),ei=nearestSourceIndex(track,Number(seg.driftEndT));
    if(si==null||ei==null)continue;if(ei<si){const t=si;si=ei;ei=t}if(ei<=si)continue;
    const startS=track.cum[si],endS=track.cum[ei],centerS=(startS+endS)/2;
    // Every normalized field is carried through (`...seg`); only the DRAWN anchors are added. The
    // previous version rebuilt a smaller object here and that is what lost `time` and the server
    // recovery fields.
    out.push({...seg,id:out.length+1,segmentId:seg.id,episodeId:seg.id,startS,endS,centerS,
      start:track.pts[si],end:track.pts[ei],center:pointAt(track,centerS),
      subjectStartIdx:si,subjectEndIdx:ei,
      nativeDurationS:Number(seg.time.duration_s)||Math.max(0,Number(seg.time.end_t)-Number(seg.time.start_t))});
  }
  return out;
}
function headingAtIndex(track,i){const a=track.pts[Math.max(0,i-3)],b=track.pts[Math.min(track.pts.length-1,i+3)];return Math.atan2(b.y-a.y,b.x-a.x)}
function upperBound(a,x){let lo=0,hi=a.length;while(lo<hi){const m=(lo+hi)>>1;if(a[m]<=x)lo=m+1;else hi=m}return lo}
function anchorCandidate(refTrack,subTrack,s,prev=0,skipAmbiguity=false){
  if(!refTrack?.pts?.length||!subTrack?.pts?.length||!(refTrack.total>0)||!(subTrack.total>0))return null;
  const rp=pointAt(refTrack,s),frac=Math.max(0,Math.min(1,Number(s)/refTrack.total)),bandFrac=.09;
  const loS=Math.max(0,(frac-bandFrac)*subTrack.total),hiS=Math.min(subTrack.total,(frac+bandFrac)*subTrack.total);
  let lo=Math.max(Number(prev)||0,lowerBound(subTrack.cum,loS)),hi=Math.min(subTrack.pts.length-1,Math.max(lo,upperBound(subTrack.cum,hiS)));
  if(lo>hi)return null;
  const headSpan=Math.max(1.5,Math.min(5,refTrack.total*.004)),fwd=pointAt(refTrack,Math.min(refTrack.total,s+headSpan)),back=pointAt(refTrack,Math.max(0,s-headSpan)),refHead=Math.atan2(fwd.y-back.y,fwd.x-back.x);
  const scale=Math.max(3,Math.min(18,Math.min(refTrack.total,subTrack.total)*.02)),items=[];
  for(let i=lo;i<=hi;i++){
    const p=subTrack.pts[i],hd=Math.abs(angleDiff(refHead,headingAtIndex(subTrack,i)));if(hd>Math.PI*.48)continue;
    const d=dist(rp,p),pf=subTrack.cum[i]/subTrack.total,pd=Math.abs(pf-frac);
    const score=d*d+(hd*scale*.9)**2+(pd*scale*8)**2;items.push({index:i,distance:d,headingDiff:hd,progressDiff:pd,score,progress:pf});
  }
  if(!items.length)return null;items.sort((a,b)=>a.score-b.score);const best=items[0];
  const alt=items.find(x=>Math.abs(x.progress-best.progress)>.012);
  const spatialLimit=Math.max(3,Math.min(18,Math.min(refTrack.total,subTrack.total)*.025));
  const ambiguous=!skipAmbiguity&&!!alt&&alt.score<=best.score*1.22+spatialLimit*spatialLimit*.06;
  const ready=best.distance<=spatialLimit&&best.headingDiff<=Math.PI*.44&&best.progressDiff<=bandFrac&&!ambiguous;
  return{...best,ready,ambiguous,spatialLimit};
}
function mapAnchorMatch(refTrack,subTrack,s,prev=0){
  const best=anchorCandidate(refTrack,subTrack,s,prev,false);if(!best?.ready)return best?{...best,ready:false,reason:best.ambiguous?'ambiguous_anchor':'anchor_out_of_bounds'}:null;
  const back=anchorCandidate(subTrack,refTrack,subTrack.cum[best.index],0,true);
  const roundTrip=back?Math.abs(refTrack.cum[back.index]-Number(s))/Math.max(refTrack.total,1):Infinity;
  const ready=!!back?.ready&&roundTrip<=.035;
  return{...best,ready,roundTrip,reason:ready?'ready':'round_trip_failed'};
}
function mapBoundaryIndex(refTrack,subTrack,s,prev){const m=mapAnchorMatch(refTrack,subTrack,s,prev);return m?.ready?m.index:null}
function mapBoundaries(refTrack,subTrack,defs){
  if(!refTrack||!subTrack||!defs.length)return null;const out=[];let prev=0;
  for(const d of defs){
    const a=mapAnchorMatch(refTrack,subTrack,d.startS,prev),c=mapAnchorMatch(refTrack,subTrack,d.centerS,a?.ready?a.index:prev),b=mapAnchorMatch(refTrack,subTrack,d.endS,c?.ready?c.index:(a?.ready?a.index:prev));
    const ready=!!a?.ready&&!!c?.ready&&!!b?.ready&&b.index>a.index&&c.index>=a.index&&c.index<=b.index;
    if(!ready){out.push({status:(a?.ambiguous||c?.ambiguous||b?.ambiguous)?'ambiguous':'unavailable',reason:a?.reason||c?.reason||b?.reason||'mapping_failed',startIdx:null,endIdx:null});continue}
    const srcSpan=Math.max(1e-6,d.endS-d.startS),dstSpan=Math.max(0,subTrack.cum[b.index]-subTrack.cum[a.index]),ratio=dstSpan/srcSpan;
    if(!(ratio>=.28&&ratio<=3.5)){out.push({status:'unavailable',reason:'mapped_span_ratio',startIdx:null,endIdx:null});continue}
    out.push({status:'ready',startIdx:a.index,centerIdx:c.index,endIdx:b.index,maxAnchorDistance:Math.max(a.distance,c.distance,b.distance),roundTripMax:Math.max(a.roundTrip,c.roundTrip,b.roundTrip),spanRatio:ratio});prev=b.index+1;
  }
  return out;
}
function sourceIndexBefore(track,t){
  if(!track?.pts?.length)return null;let i=nearestSourceIndex(track,Number(t));if(i==null)return null;
  while(i>0&&Number(track.pts[i].source_t)>=Number(t)-1e-6)i--;
  return i;
}
function sourceSampleIntervalNear(track,t){
  if(!track?.pts?.length)return .02;const i=nearestSourceIndex(track,Number(t));if(i==null)return .02;const ds=[];
  for(let j=Math.max(1,i-4);j<=Math.min(track.pts.length-1,i+4);j++){
    if(track.pts[j]?.break_before)continue;const dt=Number(track.pts[j].source_t)-Number(track.pts[j-1].source_t);
    if(Number.isFinite(dt)&&dt>0&&dt<.2)ds.push(dt);
  }
  return ds.length?quantile(ds,.5):.02;
}
function exitSmallBoostEndpoint(track,sourceStream,a,driftEndT){
  if(!track?.pts?.length||!sourceStream)return null;
  const endT=Number(driftEndT);if(!Number.isFinite(endT))return null;
  const nextStart=nextDriftStartAfter(a,endT,sourceStream),windowEnd=Math.min(Number.isFinite(nextStart)?nextStart:Infinity,endT+EXIT_SMALL_BOOST_WINDOW_S);
  const boosts=(sourceStream.small_boost_segments||[]).filter(seg=>{
    const st=Number(seg?.start_t),et=Number(seg?.end_t);return Number.isFinite(st)&&Number.isFinite(et)&&et>endT+1e-4&&st<windowEnd-1e-4;
  }).sort((x,y)=>Number(x.start_t)-Number(y.start_t)||Number(x.end_t)-Number(y.end_t));
  if(!boosts.length)return null;
  const last=boosts[boosts.length-1],nativeEnd=Number(last.end_t);
  // The recovery interval never crosses the next Drift.  Even when small-boost end and
  // the next Drift start are effectively back-to-back, they remain two UI sections;
  // visual separation is handled by drawSectorRanges without changing the native time.
  const interrupted=Number.isFinite(nextStart)&&nativeEnd>nextStart+1e-4;
  const adjacent=Number.isFinite(nextStart)&&Math.abs(nativeEnd-nextStart)<=Math.max(.002,sourceSampleIntervalNear(track,nextStart)*1.25);
  const endpointNativeT=(Number.isFinite(nextStart)&&nativeEnd>=nextStart-1e-4)?nextStart:nativeEnd;
  let idx=nearestSourceIndex(track,endpointNativeT);
  if(idx==null)return null;idx=Math.max(0,Math.min(track.pts.length-1,idx));
  return{index:idx,interrupted,adjacentToNextDrift:adjacent,smallBoostCount:boosts.length,lastSmallBoostStartT:Number(last.start_t),lastSmallBoostEndT:nativeEnd,endpointT:endpointNativeT,stopReason:interrupted?'next_drift_interrupted':adjacent?'adjacent_next_drift':'last_small_boost_end'};
}
function recoverySectorDefinition(track,a,lapNo,sourceStream){
  const defs=driftSectorDefinition(track,a,lapNo,sourceStream);
  return defs.map(d=>{
    // Published contract FIRST. When the analyzer published this segment, its recovery end is the
    // authority and the browser only maps that native time onto the drawn trajectory; it must never
    // re-infer a recovery boundary (and it must never lose the field that carries it).
    const recoveryEndT=Number.isFinite(Number(d.serverRecoveryEndT))?Number(d.serverRecoveryEndT):null;
    if(d.server===true&&recoveryEndT!=null){
      const idx=nearestSourceIndex(track,recoveryEndT);
      const recoveryEndIdx=(idx==null)?d.subjectEndIdx:Math.max(d.subjectEndIdx,idx);
      const endS=track.cum[recoveryEndIdx],centerS=(d.startS+endS)/2;
      return {...d,endS,centerS,center:pointAt(track,centerS),
        recoveryAvailable:!!d.serverRecoveryAvailable,
        recoveryInterrupted:String(d.serverRecoveryReason||'')==='next_drift_hard_cut',
        recoverySmallBoostCount:null,recoveryEndIdx,
        recoveryStopReason:String(d.serverRecoveryReason||''),
        nativeStartT:d.startT,nativeDriftEndT:d.driftEndT,nativeRecoveryEndT:recoveryEndT,
        nextDriftStartT:d.serverNextDriftStartT,recoverySource:'published_contract'};
    }
    // Compatibility path only: this side has no published segmentation contract.
    const ep=exitSmallBoostEndpoint(track,sourceStream,a,Number(d.end.source_t));
    if(!ep)return{...d,recoveryAvailable:false,recoveryInterrupted:false,recoverySmallBoostCount:0,
      recoveryEndIdx:d.subjectEndIdx,recoveryStopReason:'no_native_recovery_effect',
      nativeStartT:d.startT,nativeDriftEndT:d.driftEndT,nativeRecoveryEndT:d.driftEndT,recoverySource:'browser_compat'};
    const recoveryEndIdx=Math.max(d.subjectEndIdx,ep.index),endS=track.cum[recoveryEndIdx],centerS=(d.startS+endS)/2;
    return {...d,endS,centerS,center:pointAt(track,centerS),recoveryAvailable:true,recoveryInterrupted:ep.interrupted,
      recoveryAdjacentToNextDrift:!!ep.adjacentToNextDrift,recoverySmallBoostCount:ep.smallBoostCount,recoveryEndIdx,
      recoveryStopReason:ep.stopReason,lastSmallBoostStartT:ep.lastSmallBoostStartT,lastSmallBoostEndT:ep.lastSmallBoostEndT,
      nativeStartT:d.startT,nativeDriftEndT:d.driftEndT,nativeRecoveryEndT:Number(ep.endpointT),recoverySource:'browser_compat'};
  });
}
function driftRangesForLap(track,a,lapNo,sourceStream=null){
  const out=[];for(const ep of driftSegmentsForLap(a,lapNo,sourceStream)){const startT=Number(ep.time.start_t),endT=Number(ep.time.end_t);let si=nearestSourceIndex(track,startT),ei=nearestSourceIndex(track,endT);if(si==null||ei==null)continue;if(ei<si){const t=si;si=ei;ei=t}if(ei<=si)continue;out.push({startIdx:si,endIdx:ei,startT,endT,durationS:Number(ep.time.duration_s)||Math.max(0,endT-startT),id:String(ep.id||'')})}return out;
}
function compareDriftMatch(track,a,lapNo,startIdx,endIdx,sourceStream=null){
  if(!track||startIdx==null||endIdx==null)return{status:'none',matches:[]};
  const lo=Math.min(startIdx,endIdx),hi=Math.max(startIdx,endIdx),matches=driftRangesForLap(track,a,lapNo,sourceStream).filter(r=>r.endIdx>=lo&&r.startIdx<=hi);
  if(matches.length===1)return{status:'unique',matches,match:matches[0]};
  return{status:matches.length?'ambiguous':'none',matches};
}
function mapTrackIndex(srcTrack,dstTrack,srcIdx,prev=0){
  if(!srcTrack||!dstTrack||!Number.isInteger(srcIdx)||srcIdx<0||srcIdx>=srcTrack.pts.length)return null;
  const s=srcTrack.cum[srcIdx];if(!Number.isFinite(s))return null;const m=mapAnchorMatch(srcTrack,dstTrack,s,Math.max(0,prev||0));return m?.ready?m.index:null;
}
function nextDriftRangeAfterIndex(track,a,lapNo,afterIdx,sourceStream=null){
  return driftRangesForLap(track,a,lapNo,sourceStream).find(r=>r.startIdx>Number(afterIdx)+1)||null;
}
function naturalRecoveryRange(track,a,lapNo,sourceStream,drift){
  if(!track||!drift)return null;
  const startIdx=Number.isInteger(drift.subjectStartIdx)?drift.subjectStartIdx:drift.startIdx;
  const driftEndIdx=Number.isInteger(drift.subjectEndIdx)?drift.subjectEndIdx:drift.endIdx;
  if(!Number.isInteger(startIdx)||!Number.isInteger(driftEndIdx)||driftEndIdx<=startIdx)return null;
  const endT=Number.isFinite(Number(drift.endT))?Number(drift.endT):Number(track.pts[driftEndIdx]?.source_t);
  if(!Number.isFinite(endT))return null;
  const ep=exitSmallBoostEndpoint(track,sourceStream,a,endT);
  if(!ep)return{available:false,startIdx,driftEndIdx,endIdx:driftEndIdx,endpoint:null};
  return{available:true,startIdx,driftEndIdx,endIdx:Math.max(driftEndIdx,ep.index),endpoint:ep};
}
function mapRangeStrict(srcTrack,dstTrack,startIdx,endIdx){
  if(!srcTrack||!dstTrack||!Number.isInteger(startIdx)||!Number.isInteger(endIdx)||endIdx<=startIdx)return{status:'unavailable',reason:'invalid_range'};
  const startS=srcTrack.cum[startIdx],endS=srcTrack.cum[endIdx],midS=(startS+endS)/2;
  const a=mapAnchorMatch(srcTrack,dstTrack,startS,0),c=mapAnchorMatch(srcTrack,dstTrack,midS,a?.ready?a.index:0),b=mapAnchorMatch(srcTrack,dstTrack,endS,c?.ready?c.index:(a?.ready?a.index:0));
  if(!a?.ready||!c?.ready||!b?.ready||!(b.index>a.index)||c.index<a.index||c.index>b.index){
    return{status:(a?.ambiguous||c?.ambiguous||b?.ambiguous)?'ambiguous':'unavailable',reason:a?.reason||c?.reason||b?.reason||'range_mapping_failed'};
  }
  const srcSpan=Math.max(1e-6,endS-startS),dstSpan=Math.max(0,dstTrack.cum[b.index]-dstTrack.cum[a.index]),ratio=dstSpan/srcSpan;
  if(!(ratio>=.28&&ratio<=3.5))return{status:'unavailable',reason:'mapped_span_ratio'};
  return{status:'ready',startIdx:a.index,midIdx:c.index,endIdx:b.index,maxAnchorDistance:Math.max(a.distance,c.distance,b.distance),roundTripMax:Math.max(a.roundTrip,c.roundTrip,b.roundTrip),spanRatio:ratio};
}
function mappedRangeContainsDrift(mapped,drift,tolerance=2){
  if(!mapped||mapped.status!=='ready'||!drift)return true;
  return mapped.startIdx<=drift.startIdx+tolerance&&mapped.endIdx>=drift.endIdx-tolerance;
}
function recoveryCandidate(ownerTrack,otherTrack,natural,otherDrift,ownerIsSubject){
  if(!natural?.available)return null;
  const mapped=mapRangeStrict(ownerTrack,otherTrack,natural.startIdx,natural.endIdx);
  if(mapped.status!=='ready'||!mappedRangeContainsDrift(mapped,otherDrift))return null;
  const startA=ownerIsSubject?natural.startIdx:mapped.startIdx,endA=ownerIsSubject?natural.endIdx:mapped.endIdx;
  const startB=ownerIsSubject?mapped.startIdx:natural.startIdx,endB=ownerIsSubject?mapped.endIdx:natural.endIdx;
  if(!(endA>startA&&endB>startB))return null;
  const aTrack=ownerIsSubject?ownerTrack:otherTrack,bTrack=ownerIsSubject?otherTrack:ownerTrack;
  const spanA=Math.max(0,subjectProgressSpan(aTrack,startA,endA)),spanB=Math.max(0,subjectProgressSpan(bTrack,startB,endB));
  const normA=spanA/Math.max(1e-6,aTrack.total),normB=spanB/Math.max(1e-6,bTrack.total);
  const startProgress=((Number(aTrack.cum[startA])/Math.max(1e-6,aTrack.total))+(Number(bTrack.cum[startB])/Math.max(1e-6,bTrack.total)))/2;
  const endProgress=((Number(aTrack.cum[endA])/Math.max(1e-6,aTrack.total))+(Number(bTrack.cum[endB])/Math.max(1e-6,bTrack.total)))/2;
  const a0=aTrack.pts[startA],a1=aTrack.pts[endA],b0=bTrack.pts[startB],b1=bTrack.pts[endB];
  const signature=[(a0.x+b0.x)/2,(a0.y+b0.y)/2,(a1.x+b1.x)/2,(a1.y+b1.y)/2].map(v=>Number(v).toFixed(5)).join('|');
  return{startA,endA,startB,endB,startProgress,endProgress,spanScore:(normA+normB)/2,quality:Number(mapped.maxAnchorDistance||0)+Number(mapped.roundTripMax||0)*20,signature,endpointApprox:!!natural.endpoint?.interrupted,source:ownerIsSubject?'subject':'reference'};
}
function subjectProgressSpan(track,startIdx,endIdx){return track&&Number.isInteger(startIdx)&&Number.isInteger(endIdx)?Math.max(0,Number(track.cum[endIdx])-Number(track.cum[startIdx])):0}
function chooseCoreComparableCandidate(candidates){
  const xs=(candidates||[]).filter(Boolean);if(!xs.length)return null;
  if(xs.length===1)return{...xs[0],source:'single_natural_candidate'};
  const starts=[...xs].sort((a,b)=>a.startProgress-b.startProgress||a.quality-b.quality||a.signature.localeCompare(b.signature));
  const ends=[...xs].sort((a,b)=>a.endProgress-b.endProgress||a.quality-b.quality||a.signature.localeCompare(b.signature));
  const st=starts[0],en=ends[0],startA=st.startA,startB=st.startB,endA=en.endA,endB=en.endB;
  if(!(endA>startA&&endB>startB))return null;
  return{startA,endA,startB,endB,startProgress:st.startProgress,endProgress:en.endProgress,spanScore:Math.max(0,en.endProgress-st.startProgress),quality:Math.max(st.quality,en.quality),signature:`${st.signature}>${en.signature}`,endpointApprox:!!en.endpointApprox,source:'paired_core_window'};
}
function mappedPointIndex(srcTrack,dstTrack,srcIdx,prev){
  if(!Number.isInteger(srcIdx))return null;const m=mapAnchorMatch(srcTrack,dstTrack,srcTrack.cum[srcIdx],Math.max(0,Number(prev)||0));return m?.ready?m.index:null;
}
function applySymmetricNextDriftCut(candidate,subjectTrack,compareTrack,subjectDrift,compareDrift,subjectA,compareA){
  if(!candidate)return null;const cuts=[];
  const addCut=(sourceSide,next)=>{
    if(!next)return;
    if(sourceSide==='subject'){
      if(next.startIdx<=subjectDrift.endIdx||next.startIdx>candidate.endA)return;
      const mapped=mappedPointIndex(subjectTrack,compareTrack,next.startIdx,candidate.startB);if(!Number.isInteger(mapped)||mapped<=candidate.startB||mapped>candidate.endB)return;
      if(compareDrift&&mapped<compareDrift.endIdx-1)return;
      const ra=(subjectTrack.cum[next.startIdx]-subjectTrack.cum[candidate.startA])/Math.max(1e-6,subjectTrack.cum[candidate.endA]-subjectTrack.cum[candidate.startA]);
      const rb=(compareTrack.cum[mapped]-compareTrack.cum[candidate.startB])/Math.max(1e-6,compareTrack.cum[candidate.endB]-compareTrack.cum[candidate.startB]);
      cuts.push({endA:next.startIdx,endB:mapped,progress:(ra+rb)/2,source:'subject_next_drift'});
    }else{
      if(!compareDrift||next.startIdx<=compareDrift.endIdx||next.startIdx>candidate.endB)return;
      const mapped=mappedPointIndex(compareTrack,subjectTrack,next.startIdx,candidate.startA);if(!Number.isInteger(mapped)||mapped<=candidate.startA||mapped>candidate.endA)return;
      if(mapped<subjectDrift.endIdx-1)return;
      const ra=(subjectTrack.cum[mapped]-subjectTrack.cum[candidate.startA])/Math.max(1e-6,subjectTrack.cum[candidate.endA]-subjectTrack.cum[candidate.startA]);
      const rb=(compareTrack.cum[next.startIdx]-compareTrack.cum[candidate.startB])/Math.max(1e-6,compareTrack.cum[candidate.endB]-compareTrack.cum[candidate.startB]);
      cuts.push({endA:mapped,endB:next.startIdx,progress:(ra+rb)/2,source:'reference_next_drift'});
    }
  };
  addCut('subject',nextDriftRangeAfterIndex(subjectTrack,subjectA,currentLap,subjectDrift.endIdx,stream));
  if(compareDrift)addCut('reference',nextDriftRangeAfterIndex(compareTrack,compareA,compareLap,compareDrift.endIdx,referenceStream()));
  if(!cuts.length)return{...candidate,cutByNextDrift:false};cuts.sort((a,b)=>a.progress-b.progress||a.source.localeCompare(b.source));const cut=cuts[0];
  if(!(cut.endA>candidate.startA&&cut.endB>candidate.startB))return null;
  return{...candidate,endA:cut.endA,endB:cut.endB,cutByNextDrift:true,cutSource:cut.source};
}
function sharedRecoveryWindow(subjectTrack,compareTrack,d,m,compareA){
  if(!subjectTrack||!compareTrack||!d||!m)return null;
  const referenceSourceStream=referenceStream();
  const subjectDrift={startIdx:d.subjectStartIdx,endIdx:d.subjectEndIdx,startT:Number(d.start?.source_t),endT:Number(d.end?.source_t)};
  const dm=compareDriftMatch(compareTrack,compareA,compareLap,m.startIdx,m.endIdx,referenceSourceStream);
  let referenceDrift=dm.status==='unique'?dm.match:null,driftStatus=dm.status;
  if(referenceDrift){
    const reciprocal=mapRangeStrict(compareTrack,subjectTrack,referenceDrift.startIdx,referenceDrift.endIdx);
    if(reciprocal.status!=='ready'||!mappedRangeContainsDrift(reciprocal,subjectDrift)){referenceDrift=null;driftStatus='ambiguous'}
  }
  const subjectNatural=naturalRecoveryRange(subjectTrack,analysis,currentLap,stream,subjectDrift);
  const referenceNatural=referenceDrift?naturalRecoveryRange(compareTrack,compareA,compareLap,referenceSourceStream,referenceDrift):null;
  const candidates=[
    recoveryCandidate(subjectTrack,compareTrack,subjectNatural,referenceDrift,true),
    referenceDrift?recoveryCandidate(compareTrack,subjectTrack,referenceNatural,subjectDrift,false):null
  ];
  let chosen=chooseCoreComparableCandidate(candidates);
  if(!chosen)return{status:'unavailable',driftStatus,reason:'no_shared_comparable_recovery'};
  chosen=applySymmetricNextDriftCut(chosen,subjectTrack,compareTrack,subjectDrift,referenceDrift,analysis,compareA);
  if(!chosen)return{status:'unavailable',driftStatus,reason:'next_drift_cut_invalid'};
  const{startA,endA,startB,endB}=chosen;if(!(endA>startA&&endB>startB))return{status:'unavailable',driftStatus,reason:'empty_shared_window'};
  return{status:'ready',driftStatus,startA,endA,startB,endB,subjectTime:Math.max(0,Number(subjectTrack.pts[endA].t)-Number(subjectTrack.pts[startA].t)),referenceTime:Math.max(0,Number(compareTrack.pts[endB].t)-Number(compareTrack.pts[startB].t)),cutByNextDrift:!!chosen.cutByNextDrift,windowSource:chosen.source,spanScore:chosen.spanScore};
}

// --- authoritative A/B contract ------------------------------------------------------------------
// The numbers shown for a comparison come from the analyzer's own contract
// (native_segment_comparison_v1) over the server's published segmentation. The browser keeps its
// own drawing anchors, but it never invents a second set of comparison numbers: the windows are
// built in a canonical side order on the server, so A->B and B->A use the same world interval and
// every delta only changes sign.
// QQ Speed's client HUD renders GetKart()->GetVelocity() * SpeedDispCoef, with SpeedDispCoef=10.0.
// The verified 2026 SAV replay_linear_velocity field is NOT in that same magnitude scale. The first
// same-frame anchor (HUD 94 km/h) put the bridge close to x15. Subsequent field checks on two more
// HUD-94 points showed the x15 presentation still reading 92 and 91, i.e. a small systematic low
// bias. The display-only coefficient is therefore refined to x15.4 as a field calibration. Production
// analysis and A/B comparison remain in their raw replay-velocity contract; this is presentation only.
const GAME_SPEED_DISP_COEF=15.4;
function gameSpeedDisplay(v){const n=Number(v);if(!Number.isFinite(n))return null;return Math.trunc(Math.max(0,n*GAME_SPEED_DISP_COEF))}
const METRIC_LABELS={time_s:['核心时间','s','fixed3'],entry_speed_mps:['入弯速度','km/h','game_speed'],min_corner_speed_mps:['最低弯速','km/h','game_speed'],exit_speed_mps:['出弯速度','km/h','game_speed'],drift_distance_m:['漂移距离','m','fixed3'],recovery_distance_m:['出弯→恢复距离','m','fixed3'],total_distance_m:['起漂→恢复总距离','m','fixed3']};
function metricDisplayValue(meta,v){if(v==null)return'—';if(meta?.[2]==='game_speed'){const n=gameSpeedDisplay(v);return n==null?'—':String(n)}return fmt(v,3)}
function segmentComparisonKey(){return [currentFile,currentLap,compareFile,compareLap,compareInternalStreamId,routeMode].join('|')}
function crossReplayComparison(){return !!(compareFile&&compareFile!==currentFile)}
function comparisonSupportedMode(){return routeMode==='recovery'||routeMode==='drift'}
function segmentComparisonLoaded(){return !!(serverComparison&&serverComparison.key===segmentComparisonKey()&&serverComparison.comparison&&serverComparison.comparison.status==='ready')}
function serverWindowForSector(s){
  if(!segmentComparisonLoaded())return null;
  const t=Number(s&&s.nativeStartT);if(!Number.isFinite(t))return null;
  let best=null,bd=Infinity;
  for(const w of serverComparison.comparison.windows||[]){
    const c=w&&w.corner;if(!c)continue;
    const st=Number(crossReplayComparison()?c.subject_start_t:c.subject_start_t);
    if(!Number.isFinite(st))continue;
    const d=Math.abs(st-t);if(d<bd){bd=d;best=w}
  }
  return bd<=0.06?best:null;
}
function comparisonRequestBody(){
  return{subject_file_b64:enc(currentFile),subject_lap:String(currentLap),
    compare_file_b64:isInternalStreamCompare()?'':enc(compareFile),
    compare_stream:isInternalStreamCompare()?compareInternalStreamId:'',
    compare_lap:String(compareLap),mode:'auto'};
}
async function requestSegmentComparison(){
  const key=segmentComparisonKey();
  if(!compareFile||!compareLap||!comparisonSupportedMode()){if(comparisonRequestKey!==key){comparisonRequestKey=key;serverComparison=null}return}
  if(comparisonRequestKey===key)return;
  comparisonRequestKey=key;
  try{
    const res=await post('/api/segment-comparison',comparisonRequestBody());
    if(!res||!res.ok)throw new Error((res&&res.error)||'对比契约计算失败');
    if(comparisonRequestKey!==key)return;
    serverComparison={key,comparison:res.comparison};
    renderAll();
  }catch(e){if(comparisonRequestKey===key)serverComparison=null}
}
function clearSectorMetrics(){const box=$('sectorMetrics');if(box)box.innerHTML=''}
function renderSectorMetrics(s){
  const box=$('sectorMetrics');if(!box)return;box.innerHTML='';
  const ms=s&&s.serverMetrics;if(!ms||!ms.length)return;
  for(const m of ms){
    const meta=METRIC_LABELS[m.id]||[m.id,'','fixed3'],v=m.value||{},sub=metricDisplayValue(meta,v.subject),base=metricDisplayValue(meta,v.baseline),unit=meta[1]?` ${meta[1]}`:'';
    const row=document.createElement('div');row.className='metricRow';
    const label=document.createElement('div');label.className='metricLabel';label.textContent=meta[0];
    const a=document.createElement('div');a.className='metricValue subject';a.innerHTML=`<span>A</span><b>${sub}${unit}</b>`;
    const b=document.createElement('div');b.className='metricValue reference';b.innerHTML=`<span>B</span><b>${base}${unit}</b>`;
    row.append(label,a,b);
    box.appendChild(row);
  }
}

function sectorMetrics(subjectTrack,compareTrack,defs){
  if(!subjectTrack||!defs.length)return[];
  // The analyzer's comparison contract is the authority for the numbers AND for the drawn ranges,
  // so while it is loaded the browser correspondence is not computed at all. It used to run its own
  // monotone mapping (mapBoundaries / sharedRecoveryWindow over every anchor) on every render and
  // every pan frame even though the server had already answered.
  const serverContract=segmentComparisonLoaded();
  let mapped=null;
  if(compareTrack&&routeMode!=='all'&&!serverContract){
    // Recovery comparison must first identify the same Drift body on both replays. Never use a
    // subject-only recovery endpoint to decide which Drift on the other replay is the peer; that was
    // the source of A→B / B→A selecting different operations. This is the compatibility path.
    const mappingDefs=routeMode==='recovery'?defs.map(d=>{const startS=subjectTrack.cum[d.subjectStartIdx],endS=subjectTrack.cum[d.subjectEndIdx];return{...d,startS,endS,centerS:(startS+endS)/2}}):defs;
    mapped=mapBoundaries(subjectTrack,compareTrack,mappingDefs);
  }
  const compareA=compareFile===currentFile?analysis:compareAnalysis,refSource=referenceStream();
  return defs.map((d,i)=>{
    const subjectDriftTime=Number.isFinite(Number(d.nativeDurationS))?Math.max(0,Number(d.nativeDurationS)):Math.max(0,Number(d.end.t)-Number(d.start.t));
    const mapInfo=mapped?mapped[i]:null,m=mapInfo?.status==='ready'?mapInfo:null;let subjectTime=null,referenceTime=null,delta=null,coreSubjectTime=null,coreReferenceTime=null,coreDelta=null,recoveryGain=null,finalResultAvailable=false,referenceDriftStatus=serverContract?'not_requested':'unavailable',referenceDriftCount=0,sharedWindowSource=null,sharedSpanScore=null;
    let subjectDisplayStartIdx=d.subjectStartIdx,subjectDisplayEndIdx=d.subjectEndIdx,referenceDisplayStartIdx=m?.startIdx??null,referenceDisplayEndIdx=m?.endIdx??null,subjectEndpointApprox=false,referenceEndpointApprox=false;
    if(routeMode==='drift'){
      subjectTime=subjectDriftTime;
      if(compareTrack&&m){const dm=compareDriftMatch(compareTrack,compareA,compareLap,m.startIdx,m.endIdx,refSource);referenceDriftStatus=dm.status;referenceDriftCount=dm.matches.length;if(dm.status==='unique'){referenceTime=dm.match.durationS;referenceDisplayStartIdx=dm.match.startIdx;referenceDisplayEndIdx=dm.match.endIdx}}
    }else if(routeMode==='recovery'){
      subjectDisplayEndIdx=d.recoveryEndIdx??d.subjectEndIdx;subjectEndpointApprox=!!d.recoveryInterrupted;
      if(d.recoveryAvailable)subjectTime=Math.max(0,Number(subjectTrack.pts[subjectDisplayEndIdx].t)-Number(subjectTrack.pts[d.subjectStartIdx].t));
      if(compareTrack&&m){
        const shared=sharedRecoveryWindow(subjectTrack,compareTrack,d,m,compareA);
        referenceDriftStatus=shared?.driftStatus||'unavailable';
        if(shared?.status==='ready'){
          subjectDisplayStartIdx=shared.startA;subjectDisplayEndIdx=shared.endA;referenceDisplayStartIdx=shared.startB;referenceDisplayEndIdx=shared.endB;
          subjectTime=shared.subjectTime;referenceTime=shared.referenceTime;subjectEndpointApprox=!!shared.cutByNextDrift;referenceEndpointApprox=!!shared.cutByNextDrift;
          sharedWindowSource=shared.windowSource;sharedSpanScore=shared.spanScore;
        }else referenceTime=null;
      }
    }
    if(subjectTime!=null&&referenceTime!=null)delta=subjectTime-referenceTime;
    // Server contract wins over the browser estimate for the numbers that are shown.
    let serverMetrics=null,serverWindowId=null;
    const sw=(routeMode==='recovery'||routeMode==='drift')?serverWindowForSector(d):null;
    if(sw&&sw.status==='comparable'&&sw.time&&sw.time.subject_s!=null&&sw.time.baseline_s!=null){
      const ct=sw.core_time||sw.time;
      coreSubjectTime=Number(ct.subject_s);coreReferenceTime=Number(ct.baseline_s);coreDelta=Number(ct.delta_s);
      if(routeMode==='recovery'&&sw.final_time&&sw.final_time.available&&sw.final_time.subject_s!=null&&sw.final_time.baseline_s!=null){
        subjectTime=Number(sw.final_time.subject_s);referenceTime=Number(sw.final_time.baseline_s);delta=Number(sw.final_time.delta_s);
        recoveryGain=Number(sw.recovery_strategy?.subject_net_gain_s);finalResultAvailable=Number.isFinite(delta);
        subjectEndpointApprox=!!(sw.space&&sw.space.final_hard_cut_applied)||subjectEndpointApprox;
        referenceEndpointApprox=!!(sw.space&&sw.space.final_hard_cut_applied)||referenceEndpointApprox;
      }else{
        subjectTime=coreSubjectTime;referenceTime=coreReferenceTime;delta=coreDelta;
        subjectEndpointApprox=!!(sw.space&&sw.space.hard_cut_applied)||subjectEndpointApprox;
        referenceEndpointApprox=!!(sw.space&&sw.space.hard_cut_applied)||referenceEndpointApprox;
      }
      serverMetrics=sw.metrics||null;serverWindowId=String(sw.window_id||'');
      if(routeMode==='drift'){const paired=(sw.corner&&sw.corner.baseline_segment_index!=null);referenceDriftStatus=paired?'unique':'none';referenceDriftCount=paired?1:0}
    }
    // Drawn reference range, taken from the published native times (no browser correspondence).
    if(serverContract&&compareTrack&&sw&&sw.corner){
      const c=sw.corner;
      const bStart=Number(c.baseline_start_t),bEnd=(Number.isFinite(Number(c.baseline_recovery_end_t))?Number(c.baseline_recovery_end_t):Number(c.baseline_drift_end_t));
      if(Number.isFinite(bStart)){const k=nearestSourceIndex(compareTrack,bStart);if(k!=null)referenceDisplayStartIdx=k}
      if(Number.isFinite(bEnd)){const k=nearestSourceIndex(compareTrack,bEnd);if(k!=null)referenceDisplayEndIdx=k}
    }
    const safeEnd=subjectDisplayEndIdx==null?subjectDisplayStartIdx:subjectDisplayEndIdx,centerIdx=Math.max(subjectDisplayStartIdx,Math.min(subjectTrack.pts.length-1,Math.round((subjectDisplayStartIdx+safeEnd)/2))),centerS=subjectTrack.cum[centerIdx]??d.centerS;
    return {...d,centerS,subjectTime,referenceTime,delta,coreSubjectTime,coreReferenceTime,coreDelta,recoveryGain,finalResultAvailable,startIdx:m?.startIdx??null,endIdx:m?.endIdx??null,subjectDisplayStartIdx,subjectDisplayEndIdx,referenceDisplayStartIdx,referenceDisplayEndIdx,referenceDriftStatus,referenceDriftCount,mappingStatus:mapInfo?.status||(serverContract?'published_contract':(compareTrack?'unavailable':'not_requested')),mappingReason:mapInfo?.reason||'',mappingMaxDistance:mapInfo?.maxAnchorDistance??null,mappingRoundTrip:mapInfo?.roundTripMax??null,subjectEndpointApprox,referenceEndpointApprox,sharedWindowSource,sharedSpanScore,serverMetrics,serverWindowId};
  });
}



function resetCustomPath(keepSubject=false){
  customPath={subjectStartIdx:keepSubject?customPath.subjectStartIdx:null,subjectEndIdx:keepSubject?customPath.subjectEndIdx:null,referenceStartIdx:null,referenceEndIdx:null,dragHandle:null};
}
function customSubjectReady(){return Number.isInteger(customPath.subjectStartIdx)&&Number.isInteger(customPath.subjectEndIdx)&&customPath.subjectEndIdx>customPath.subjectStartIdx}
function customReferenceReady(){return Number.isInteger(customPath.referenceStartIdx)&&Number.isInteger(customPath.referenceEndIdx)&&customPath.referenceEndIdx>customPath.referenceStartIdx}
function clampOrderedPair(start,end,max){start=Math.max(0,Math.min(max,start));end=Math.max(0,Math.min(max,end));if(end<start){const t=start;start=end;end=t}return[start,end]}
function autoMapCustomReference(subjectTrack,referenceTrack){
  if(!subjectTrack||!referenceTrack||!customSubjectReady()){customPath.referenceStartIdx=null;customPath.referenceEndIdx=null;return}
  // A alone defines the spatial interval. B is always sampled at the same world-space
  // entry/exit positions (XY + heading, with a bounded progress band); there are no
  // independent B handles and no independently chosen B interval.
  const s0=subjectTrack.cum[customPath.subjectStartIdx],s1=subjectTrack.cum[customPath.subjectEndIdx];
  const a=mapBoundaryIndex(subjectTrack,referenceTrack,s0,0),b=Number.isInteger(a)?mapBoundaryIndex(subjectTrack,referenceTrack,s1,a):null;
  if(Number.isInteger(a)&&Number.isInteger(b)&&b>a){customPath.referenceStartIdx=a;customPath.referenceEndIdx=b}else{customPath.referenceStartIdx=null;customPath.referenceEndIdx=null}
}
function nearestTrackIndexScreen(e,track,maxPx=22){
  const c=$('route'),r=c.getBoundingClientRect();if(!track?.pts?.length||!c._project)return null;const px=e.clientX-r.left,py=e.clientY-r.top;let best=null,bd=Infinity;
  for(let i=0;i<track.pts.length;i++){const q=c._project(track.pts[i]),d=Math.hypot(px-q[0],py-q[1]);if(d<bd){bd=d;best=i}}
  return bd<=maxPx?best:null;
}
function customMetric(subjectTrack,referenceTrack){
  if(!subjectTrack||!customSubjectReady())return null;
  const st=customPath.subjectStartIdx,et=customPath.subjectEndIdx,subjectTime=Math.max(0,Number(subjectTrack.pts[et].t)-Number(subjectTrack.pts[st].t));
  let referenceTime=null;if(referenceTrack&&customReferenceReady())referenceTime=Math.max(0,Number(referenceTrack.pts[customPath.referenceEndIdx].t)-Number(referenceTrack.pts[customPath.referenceStartIdx].t));
  return{subjectTime,referenceTime,delta:referenceTime==null?null:subjectTime-referenceTime};
}
function customHandleScreenHits(){return $('route')._customHandles||[]}
function hitCustomHandle(e){const c=$('route'),r=c.getBoundingClientRect(),px=e.clientX-r.left,py=e.clientY-r.top;let best=null,bd=Infinity;for(const h of customHandleScreenHits()){const d=Math.hypot(px-h.q[0],py-h.q[1]);if(d<bd){bd=d;best=h}}return bd<=16?best:null}
function drawCustomHandle(ctx,q,label,color,key){ctx.save();ctx.beginPath();ctx.arc(q[0],q[1],8,0,Math.PI*2);ctx.fillStyle=color;ctx.fill();ctx.lineWidth=2;ctx.strokeStyle='#fff';ctx.stroke();ctx.fillStyle='#fff';ctx.font='700 8px system-ui,sans-serif';ctx.textAlign='center';ctx.textBaseline='middle';ctx.fillText(label,q[0],q[1]+.5);ctx.restore();$('route')._customHandles.push({key,q})}
function renderCustomInspector(subjectTrack,referenceTrack){
  clearSectorMetrics();const m=customMetric(subjectTrack,referenceTrack),hero=$('deltaHero');$('sectorDeltaLabel').textContent='自定义路径';$('sectorTitle').textContent='自定义路径';$('sectorIndex').textContent='手动';
  if(!customSubjectReady()){ $('sectorDelta').textContent='—';$('subjectTime').textContent='—';$('referenceTime').textContent='—';hero.className='deltaHero neutral';$('sectorDirection').textContent='先在 A 蓝色路线依次点起点、终点';$('sectorNote').textContent='A 当前圈定义唯一空间区间；B 对比圈自动取经过同一世界坐标起点和终点时的真实时间。';return}
  $('subjectTime').textContent=`${fmt(m.subjectTime,3)}s`;$('referenceTime').textContent=m.referenceTime==null?'—':`${fmt(m.referenceTime,3)}s`;
  if(m.delta==null){$('sectorDelta').textContent='—';hero.className='deltaHero neutral';$('sectorDirection').textContent=compareFile?'B 对比圈尚未形成有效起终点':'未选择 B 对比对象';}
  else{const dv=timeDeltaView(m.delta);$('sectorDelta').textContent=dv.text;hero.className='deltaHero '+dv.state;$('sectorDirection').textContent=dv.direction;}
  $('sectorNote').textContent='A 当前圈定义空间起终点；B 对比圈只测经过相同世界坐标区间的真实时间，不再单独选择或拖动 B 端点。';
  setTimeout(clampInspectorPosition,0);
}

function currentRecord(){return recordFor(currentFile)}
function currentComparisonRecord(){return compareFile?recordFor(compareFile):null}
function currentLapExists(lap){return !!(stream?.laps||[]).some(l=>String(l.lap)===String(lap))}
function referenceLapExists(lap){const s=referenceStream();return !!(s?.laps||[]).some(l=>String(l.lap)===String(lap))}
async function syncCompareLapToCurrent(){
  if(!compareFile)return;
  // Same-replay lap comparison intentionally keeps A and B independent.  When A moves onto B's
  // current lap, rebuildCompareLapOptions selects another real lap instead of collapsing both sides
  // onto the same lap. External replays / network shadows keep the established same-lap sync.
  if(isSameReplayLapCompare()){await rebuildCompareLapOptions();return}
  const target=String(currentLap||'');
  if(!target)return;
  if(referenceLapExists(target))compareLap=target;
  await rebuildCompareLapOptions();
}
async function syncCurrentLapToCompare(){
  // B is an independent lap selector when both sides come from the same local replay.
  if(isSameReplayLapCompare()){await rebuildCompareLapOptions();return}
  const target=String(compareLap||'');
  if(!target)return;
  if(currentLapExists(target))currentLap=target;
  const cur=$('currentLap');if(cur)cur.value=currentLap;
  await rebuildCompareLapOptions();
}
async function openRecord(file){
  currentFile=file;renderList();$('empty').classList.add('hidden');$('content').classList.remove('hidden');
  [analysis,telemetry]=await Promise.all([loadAnalysis(file),loadTelemetry(file)]);stream=localStream(telemetry);
  analysisRevision++;invalidateViewModel();
  const vm=await loadVisualMap(analysis);mapMeta=vm.meta;mapImage=vm.image;borrowedMapMeta=null;borrowedMapImage=null;borrowedMapSource='';
  if(!mapMeta||!mapImage){const bv=await loadUniqueSameNameVisual(currentRecord());borrowedMapMeta=bv.meta;borrowedMapImage=bv.image;borrowedMapSource=bv.source||''}
  currentLap=firstLap(stream);compareFile='';compareLap='';compareInternalStreamId='';compareAnalysis=null;compareTelemetry=null;compareStream=null;compareMapMeta=null;compareMapImage=null;
  selectedSector=null;hoverSector=null;resetCustomPath();view={zoom:1,panX:0,panY:0,drag:false,moved:false,x:0,y:0};
  await buildSelectors();renderAll();
}
async function buildSelectors(){
  const cur=$('currentLap'),cmpReplay=$('compareReplay'),cmpLap=$('compareLap'),laps=stream?.laps||[];
  cur.innerHTML='';for(const l of laps){const o=document.createElement('option');o.value=String(l.lap);o.textContent=`圈 ${l.lap} · ${fmt(l.duration_s,3)}s`;cur.appendChild(o)}cur.value=currentLap;cur.disabled=laps.length<=1;
  cur.onchange=async()=>{currentLap=cur.value;resetCustomPath();selectedSector=null;hoverSector=null;await syncCompareLapToCurrent();renderAll()};

  cmpReplay.innerHTML='<option value="">不对比</option>';
  const self=currentRecord(),selfComparable=laps.length>1;
  if(selfComparable){const o=document.createElement('option');o.value=currentFile;o.textContent=`本录像 · 圈间比较 · ${laps.length}圈`;o.title='比较同一录像中的两个不同圈次';cmpReplay.appendChild(o)}
  const nets=networkStreams(telemetry);
  for(const ns of nets){const o=document.createElement('option');o.value=compareTargetKeyForStream(ns);const hz=Number(ns?.sample_hz);o.textContent=`本录像 · 联网低频影子${streamIdOf(ns)?' · '+streamIdOf(ns):''}${Number.isFinite(hz)?' · '+fmt(hz,2)+'Hz':''}`;cmpReplay.appendChild(o)}
  const external=[];
  for(const r of records){if(r.file===currentFile||!sameMapCompatible(self,r))continue;external.push(r);const o=document.createElement('option');o.value=r.file;const shortName=compactReplayLabel(r)||'录像';o.textContent=`${shortName} · ${recordDurationText(r)}`;o.title=labelOf(r);cmpReplay.appendChild(o)}
  const hasCompareTarget=selfComparable||nets.length>0||external.length>0;
  setCompareControlEnabled(hasCompareTarget);
  if(!hasCompareTarget){compareFile='';compareLap='';compareInternalStreamId='';cmpReplay.value='';await rebuildCompareLapOptions();return}
  if(isInternalStreamCompare()){cmpReplay.value=compareTargetKeyForStream(compareStream)}else cmpReplay.value=compareFile;
  cmpReplay.onchange=async()=>{
    const raw=cmpReplay.value;compareLap='';compareInternalStreamId='';compareAnalysis=null;compareTelemetry=null;compareStream=null;compareMapMeta=null;compareMapImage=null;
    if(raw.startsWith('__stream__:')){
      const sid=raw.slice('__stream__:'.length);const target=(telemetry?.streams||[]).find(s=>streamIdOf(s)===sid&&s.role==='network_low_frequency')||null;
      if(target){compareFile=currentFile;compareInternalStreamId=sid;compareAnalysis=analysis;compareTelemetry=telemetry;compareStream=target;compareMapMeta=mapMeta;compareMapImage=mapImage}else compareFile='';
    }else{
      compareFile=raw;
      if(compareFile===currentFile){
        // Local lap-vs-lap uses the same authoritative analysis/telemetry object twice, with two
        // different lap windows. No second load and no geometry-based lap guessing is introduced.
        compareAnalysis=analysis;compareTelemetry=telemetry;compareStream=stream;compareMapMeta=mapMeta;compareMapImage=mapImage;
      }else if(compareFile){
        [compareAnalysis,compareTelemetry]=await Promise.all([loadAnalysis(compareFile),loadTelemetry(compareFile)]);compareStream=localStream(compareTelemetry);
        const vm=await loadVisualMap(compareAnalysis);compareMapMeta=vm.meta;compareMapImage=vm.image;
      }
    }
    await rebuildCompareLapOptions();customPath.referenceStartIdx=null;customPath.referenceEndIdx=null;selectedSector=null;hoverSector=null;renderAll();
  };
  await rebuildCompareLapOptions();
}
async function rebuildCompareLapOptions(){
  const sel=$('compareLap');sel.innerHTML='';
  if(!compareFile){sel.disabled=true;const o=document.createElement('option');o.textContent='—';o.value='';sel.appendChild(o);compareLap='';updateCompareRule();return}
  const s=referenceStream(),internal=isInternalStreamCompare(),sameReplay=isSameReplayLapCompare();
  // A local replay may be used as both sides, but never with the exact same lap on A and B.
  // This is an identity/window rule, not a spatial heuristic: the lap numbers come directly from
  // the replay-native lap table already published by telemetry.
  const laps=(s?.laps||[]).filter(l=>internal||!sameReplay||String(l.lap)!==String(currentLap));
  if(!laps.length){sel.disabled=true;const o=document.createElement('option');o.textContent=internal?'低频影子没有可用圈信息':'没有可比圈';o.value='';sel.appendChild(o);compareLap='';updateCompareRule();return}
  sel.disabled=false;const placeholder=document.createElement('option');placeholder.value='';placeholder.textContent='请选择对比圈';sel.appendChild(placeholder);
  for(const l of laps){const o=document.createElement('option');o.value=String(l.lap);o.textContent=`圈 ${l.lap} · ${fmt(l.duration_s,3)}s`;sel.appendChild(o)}
  const sameLap=(!sameReplay)&&laps.some(l=>String(l.lap)===String(currentLap))?String(currentLap):'';
  if(!compareLap||!laps.some(l=>String(l.lap)===String(compareLap)))compareLap=sameReplay?String(laps[0].lap):sameLap;
  sel.value=compareLap;sel.onchange=async()=>{compareLap=sel.value;customPath.referenceStartIdx=null;customPath.referenceEndIdx=null;selectedSector=null;hoverSector=null;await syncCurrentLapToCompare();renderAll()};updateCompareRule();
}
function updateCompareRule(){
  const r=currentRecord(),key=comparisonKey(r);
  if(!compareFile){$('compareRule').textContent=key?'同图可按 Resource / GameID / 同名地图匹配；默认不对比。':'当前没有可用于同图匹配的信息。';return}
  if(isInternalStreamCompare()){$('compareRule').textContent='本录像：本地高频影子 ↔ 联网低频影子；默认同圈号比较。';return}
  if(isSameReplayLapCompare()){$('compareRule').textContent=`本录像圈间比较：A 圈${currentLap||'—'} ↔ B 圈${compareLap||'—'}；两圈独立选择，不跨圈猜测。`;return}
  const target=recordFor(compareFile);
  $('compareRule').textContent=`同图依据：${comparisonBasis(r,target)||'未确认'}。`;
}
function getSubjectTrack(){return buildTrack(lapView(stream,currentLap,routeViewEndT(analysis,stream,currentLap)))}
function getReferenceTrack(){if(!compareFile||!compareLap)return null;const a=compareFile===currentFile?analysis:compareAnalysis,s=referenceStream();return buildTrack(lapView(s,compareLap,routeViewEndT(a,s,compareLap)))}
// --- derived view model (analysis vs purely visual) ------------------------------------------
// Building the drawn analysis view model means: lap view, track build, segment definition, spatial
// comparison, sector metrics. NONE of that depends on pan, zoom, hover or the selected marker. The
// view model is therefore cached and rebuilt only when something that can change the DATA changes
// (replay, lap, comparison source, route mode, custom-path boundaries, or the arrival of the
// authoritative comparison contract). `viewRevision` counts those rebuilds, so the regression can
// prove that a pan/zoom frame performs zero analysis work.
function referenceAnalysisFor(){return compareFile===currentFile?analysis:compareAnalysis}
function viewStateKey(){
  return [currentFile,currentLap,compareFile,compareLap,compareInternalStreamId,routeMode,analysisRevision,
    customPath.subjectStartIdx,customPath.subjectEndIdx,customPath.referenceStartIdx,customPath.referenceEndIdx,
    (serverComparison&&serverComparison.key)||''].join('|');
}
function ensureViewModel(){
  const key=viewStateKey();
  if(viewModel&&viewKey===key)return viewModel;
  const subjectTrack=buildTrack(lapView(stream,currentLap,routeViewEndT(analysis,stream,currentLap)));
  const refStream=referenceStream(),refAnalysis=referenceAnalysisFor();
  const referenceTrack=(compareFile&&compareLap)?buildTrack(lapView(refStream,compareLap,routeViewEndT(refAnalysis,refStream,compareLap))):null;
  const defs=routeMode==='custom'?[]:(routeMode==='recovery'?recoverySectorDefinition(subjectTrack,analysis,currentLap,stream):driftSectorDefinition(subjectTrack,analysis,currentLap,stream));
  const sectors=routeMode==='custom'?[]:sectorMetrics(subjectTrack,referenceTrack,defs);
  const driftRangesSubject=routeMode==='drift'?driftRangesForLap(subjectTrack,analysis,currentLap,stream):null;
  const driftRangesReference=(routeMode==='drift'&&referenceTrack)?driftRangesForLap(referenceTrack,refAnalysis,compareLap,refStream):null;
  viewModel={key,subjectTrack,referenceTrack,defs,sectors,driftRangesSubject,driftRangesReference};
  viewKey=key;viewRevision++;
  return viewModel;
}
function invalidateViewModel(){viewModel=null;viewKey=''}
function getSubjectTrack(){return ensureViewModel().subjectTrack}
function getReferenceTrack(){return ensureViewModel().referenceTrack}
function redrawCanvas(){const vm=ensureViewModel();drawRoute(vm.referenceTrack,vm.subjectTrack)}
function renderAll(){
  fitMapViewportHeight();
  const vm=ensureViewModel();
  const subjectTrack=vm.subjectTrack,referenceTrack=vm.referenceTrack;
  sectors=vm.sectors;
  if(routeMode==='custom'&&referenceTrack&&customSubjectReady())autoMapCustomReference(subjectTrack,referenceTrack);
  $('title').textContent=analysis?.map_name||analysis?.map_hint||analysis?.replay_file||'录像';$('fileHint').textContent=compactReplaySource(currentRecord())||withoutSav(fileBaseName(analysis?.replay_file||currentFile));
  const rid=resourceIdOf(analysis),gid=gameIdOf(analysis);const mapReady=analysis?.native_map?.status==='ready';
  $('mapBadge').textContent=mapReady?`Map ${rid} · ready`:gid?`Game ${gid} · 赛道已识别`:'赛道身份待确认';$('mapBadge').className='badge '+(mapReady?'good':'warn');
  $('recordMeta').textContent=`${fmt(stream?.duration_s,3)}s · ${stream?.laps?.length||0}圈 · ${fmt(stream?.sample_hz,2)}Hz`;
  const subject=lapView(stream,currentLap),base=compareFile&&compareLap?lapView(referenceStream(),compareLap):null;
  const lapDelta=subject&&base?Number(subject.duration_s)-Number(base.duration_s):null,ld=$('lapDelta'),lapViewDelta=timeDeltaView(lapDelta);ld.textContent=lapViewDelta.text;ld.className=lapDelta==null?'':lapViewDelta.state;
  $('compareState').textContent=base?'A 当前圈 vs B 对比圈':(compareFile?'B 已选择 · 请选择可比圈':'未选择 B 对比对象');
  const currentName=compactReplayLabel(currentRecord())||'当前录像',referenceName=isInternalStreamCompare()?'联网低频影子':(compactReplayLabel(currentComparisonRecord())||'未选择');
  if($('currentReplayName'))$('currentReplayName').textContent=currentName;if($('compareReplayName'))$('compareReplayName').textContent=compareFile?referenceName:'未选择';
  $('currentIdentityText').textContent=identitySummary(currentFile,currentLap,'subject');
  $('compareIdentityText').textContent=base?identitySummary(compareFile,compareLap,'reference'):'对比 · 未选择';
  $('compareIdentity').classList.toggle('hidden',!base);
  if(selectedSector!=null&&!sectors.some(s=>s.id===selectedSector))selectedSector=null;
  drawRoute(referenceTrack,subjectTrack);if(routeMode==='custom')renderCustomInspector(subjectTrack,referenceTrack);else renderInspector();
  const modeLabel=routeMode==='drift'?'仅漂移':routeMode==='recovery'?'起漂→恢复结束':routeMode==='custom'?'自定义路径':'全部路线';$('topState').textContent=routeMode==='custom'?(customSubjectReady()?(base?'自定义路径 · 已选区间 · 对比中':'自定义路径 · 已选区间 · 未对比'):'自定义路径 · 请在蓝线选择起点和终点'):(base?`${modeLabel} · ${sectors.length}段 · 对比中`:`${modeLabel} · ${sectors.length}段 · 未对比`);
  // Kick the authoritative comparison contract whenever the subject / counterpart / mode changed.
  setTimeout(clampInspectorPosition,0);
  requestSegmentComparison();
}

function fitCanvas(c){const r=c.getBoundingClientRect(),d=Math.max(1,window.devicePixelRatio||1),w=Math.max(1,Math.round(r.width*d)),h=Math.max(1,Math.round(r.height*d));if(c.width!==w||c.height!==h){c.width=w;c.height=h}const x=c.getContext('2d');x.setTransform(d,0,0,d,0,0);return{x,w:r.width,h:r.height}}
function transformed(q,w,h){const cx=w/2,cy=h/2;return[(q[0]-cx)*view.zoom+cx+view.panX,(q[1]-cy)*view.zoom+cy+view.panY]}
function worldToMap(p,m,w,h){
  const tr=m?.render_transform;if(!tr)return null;const mw=Number(tr.canvas_width)||1200,mh=Number(tr.canvas_height)||1200,fit=Math.min(w/mw,h/mh),dw=mw*fit,dh=mh*fit,ox=(w-dw)/2,oy=(h-dh)/2;
  const px=Number(tr.offset_x||0)+(Number(p.x)-Number(tr.world_min_x))*Number(tr.scale),py0=Number(tr.offset_y||0)+(Number(p.y)-Number(tr.world_min_y))*Number(tr.scale),py=tr.y_inverted!==false?mh-py0:py0;
  return [ox+px*fit,oy+py*fit,dw,dh,ox,oy];
}
function projectedBounds(tracks,w,h){const pts=tracks.flatMap(t=>t?.pts||[]);if(!pts.length)return()=>[w/2,h/2];let minx=Infinity,maxx=-Infinity,miny=Infinity,maxy=-Infinity;for(const p of pts){minx=Math.min(minx,p.x);maxx=Math.max(maxx,p.x);miny=Math.min(miny,p.y);maxy=Math.max(maxy,p.y)}const sx=Math.max(1,maxx-minx),sy=Math.max(1,maxy-miny),pad=36,fit=Math.min((w-pad*2)/sx,(h-pad*2)/sy),ox=(w-sx*fit)/2,oy=(h-sy*fit)/2;return p=>transformed([ox+(p.x-minx)*fit,h-(oy+(p.y-miny)*fit)],w,h)}
function colorForDelta(d){if(d==null)return'#8b96a6';if(d>0)return'#d14343';if(d<0)return'#35a55d';return'#8b96a6'}
function rectOverlap(a,b,pad=0){return a.x-pad<b.x+b.w+pad&&a.x+a.w+pad>b.x-pad&&a.y-pad<b.y+b.h+pad&&a.y+a.h+pad>b.y-pad}
function pointInRect(p,r,pad=0){return p[0]>=r.x-pad&&p[0]<=r.x+r.w+pad&&p[1]>=r.y-pad&&p[1]<=r.y+r.h+pad}
function routeScreenSamples(track,project,maxSamples=400){
  if(!track?.pts?.length)return[];const step=Math.max(1,Math.ceil(track.pts.length/maxSamples)),out=[];
  for(let i=0;i<track.pts.length;i+=step){const q=project(track.pts[i]);if(q)out.push(q)}
  const last=project(track.pts[track.pts.length-1]);if(last)out.push(last);return out;
}
function screenTangentAt(track,s,project){
  if(!track?.pts?.length)return[1,0];const i=Math.max(0,Math.min(track.pts.length-1,lowerBound(track.cum,Math.max(0,Math.min(track.total,Number(s)||0))))),a=project(track.pts[Math.max(0,i-3)]),b=project(track.pts[Math.min(track.pts.length-1,i+3)]);let dx=(b?.[0]??0)-(a?.[0]??0),dy=(b?.[1]??0)-(a?.[1]??0),m=Math.hypot(dx,dy);if(!Number.isFinite(m)||m<1e-6)return[1,0];return[dx/m,dy/m];
}
function chooseSectorLabel(ctx,q,text,w,h,occupied,routePoints,tangent){
  const measured=ctx?.measureText?ctx.measureText(text):null,tw=Math.max(32,Number(measured?.width)||String(text).length*7),th=16,padX=4;
  const t=tangent||[1,0],n=[-t[1],t[0]],distN=25,distD=28;
  const offsets=[[n[0]*distN,n[1]*distN],[-n[0]*distN,-n[1]*distN],[distD,-18],[distD,18],[-distD,-18],[-distD,18],[0,-30],[0,30]];
  let best=null,bestScore=Infinity;
  for(let i=0;i<offsets.length;i++){
    const cx=q[0]+offsets[i][0],cy=q[1]+offsets[i][1],r={x:cx-tw/2-padX,y:cy-th/2,w:tw+padX*2,h:th};let score=i*.08;
    if(r.x<4)score+=(4-r.x)*25;if(r.y<4)score+=(4-r.y)*25;if(r.x+r.w>w-4)score+=(r.x+r.w-(w-4))*25;if(r.y+r.h>h-4)score+=(r.y+r.h-(h-4))*25;
    for(const o of occupied||[])if(rectOverlap(r,o,2))score+=5000;
    for(const rp of routePoints||[])if(pointInRect(rp,r,2))score+=60;
    if(score<bestScore){bestScore=score;best={x:cx,y:cy,rect:r,score}}
  }
  return best;
}
function drawTrackLine(ctx,track,project,color,width,alpha=1,startIdx=0,endIdx=null){if(!track?.pts?.length)return;endIdx=endIdx==null?track.pts.length-1:endIdx;ctx.save();ctx.globalAlpha=alpha;ctx.beginPath();for(let i=startIdx;i<=endIdx;i++){const q=project(track.pts[i]);if(i===startIdx||track.pts[i]?.break_before)ctx.moveTo(q[0],q[1]);else ctx.lineTo(q[0],q[1])}ctx.strokeStyle=color;ctx.lineWidth=width;ctx.lineCap='round';ctx.lineJoin='round';ctx.stroke();ctx.restore()}
function drawDriftTrack(ctx,track,ranges,project,color,width,alpha=1){
  for(const r of (ranges||[])){ if(r&&r.endIdx>r.startIdx)drawTrackLine(ctx,track,project,color,width,alpha,r.startIdx,r.endIdx) }
}
function drawSectorRanges(ctx,track,items,project,color,width,alpha=1,side='subject'){
  if(!track)return;
  const ranges=(items||[]).map(s=>({
    si:side==='subject'?s.subjectDisplayStartIdx:s.referenceDisplayStartIdx,
    ei:side==='subject'?s.subjectDisplayEndIdx:s.referenceDisplayEndIdx
  })).filter(r=>r.si!=null&&r.ei!=null&&r.ei>r.si);
  for(let k=0;k<ranges.length;k++){
    let{si,ei}=ranges[k];const prev=ranges[k-1],next=ranges[k+1];
    // Recovery sections are separate operations even when one native endpoint lands on
    // exactly the same telemetry sample as the next Drift start.  Keep timing/data
    // endpoints intact, but trim one display sample at a touching boundary so two
    // operations never render as one continuous polyline.
    if(prev&&si<=prev.ei+1&&ei-si>2)si++;
    if(next&&ei>=next.si-1&&ei-si>2)ei--;
    if(ei>si)drawTrackLine(ctx,track,project,color,width,alpha,si,ei);
  }
}
function effectiveMap(){
  if(mapMeta&&mapImage)return{meta:mapMeta,image:mapImage,source:'current'};
  if(compareMapMeta&&compareMapImage)return{meta:compareMapMeta,image:compareMapImage,source:'compare'};
  if(borrowedMapMeta&&borrowedMapImage)return{meta:borrowedMapMeta,image:borrowedMapImage,source:'same-name'};
  return null;
}
function drawOfficialMap(ctx,w,h,visual){
  if(!visual?.meta||!visual?.image)return false;const tr=visual.meta.render_transform,mw=Number(tr?.canvas_width)||1200,mh=Number(tr?.canvas_height)||1200,fit=Math.min(w/mw,h/mh),dw=mw*fit,dh=mh*fit,base=[(w-dw)/2,(h-dh)/2],tl=transformed(base,w,h);
  ctx.save();ctx.globalAlpha=.72;ctx.drawImage(visual.image,tl[0],tl[1],dw*view.zoom,dh*view.zoom);ctx.restore();return true;
}
function drawRoute(referenceTrack,subjectTrack){
  const c=$('route'),{x,w,h}=fitCanvas(c);x.clearRect(0,0,w,h);x.fillStyle='#f8fafc';x.fillRect(0,0,w,h);if(!subjectTrack)return;
  const visual=effectiveMap();drawOfficialMap(x,w,h,visual);
  const project=visual? p=>transformed(worldToMap(p,visual.meta,w,h),w,h):projectedBounds([subjectTrack,referenceTrack],w,h);c._project=project;c._hits=[];
  const compareA=compareFile===currentFile?analysis:compareAnalysis;
  c._customHandles=[];
  if(routeMode==='custom'){
    if(referenceTrack)drawTrackLine(x,referenceTrack,project,'#e56b22',1.5,.28);
    drawTrackLine(x,subjectTrack,project,'#2563eb',1.8,.34);
    if(customSubjectReady())drawTrackLine(x,subjectTrack,project,'#2563eb',4.0,1,customPath.subjectStartIdx,customPath.subjectEndIdx);
    if(referenceTrack&&customReferenceReady())drawTrackLine(x,referenceTrack,project,'#e56b22',4.0,.95,customPath.referenceStartIdx,customPath.referenceEndIdx);
    if(Number.isInteger(customPath.subjectStartIdx)){const q=project(subjectTrack.pts[customPath.subjectStartIdx]);drawCustomHandle(x,q,'起','#2563eb','subjectStartIdx')}
    if(Number.isInteger(customPath.subjectEndIdx)){const q=project(subjectTrack.pts[customPath.subjectEndIdx]);drawCustomHandle(x,q,'终','#2563eb','subjectEndIdx')}
  }else if(routeMode==='all'){
    if(referenceTrack)drawTrackLine(x,referenceTrack,project,'#e56b22',2.0,.82);
    drawTrackLine(x,subjectTrack,project,'#2563eb',2.6,.96);
  }else if(routeMode==='drift'){
    const vm=viewModel||{};
    if(referenceTrack)drawDriftTrack(x,referenceTrack,vm.driftRangesReference||driftRangesForLap(referenceTrack,compareA,compareLap,referenceStream()),project,'#e56b22',2.0,.82);
    drawDriftTrack(x,subjectTrack,vm.driftRangesSubject||driftRangesForLap(subjectTrack,analysis,currentLap,stream),project,'#2563eb',2.8,.96);
  }else{
    if(referenceTrack)drawSectorRanges(x,referenceTrack,sectors,project,'#e56b22',2.0,.82,'reference');
    drawSectorRanges(x,subjectTrack,sectors,project,'#2563eb',2.8,.96,'subject');
  }
  const start=subjectTrack.pts[0],sq=project(start);x.save();x.beginPath();x.arc(sq[0],sq[1],3,0,Math.PI*2);x.fillStyle='#2563eb';x.fill();x.font='10px system-ui,sans-serif';x.fillStyle='#718096';x.fillText('起',sq[0]+5,sq[1]-4);x.restore();
  const markerRows=[];
  for(const s of sectors){
    const centerOnSubject=pointAt(subjectTrack,Math.min(subjectTrack.total,s.centerS));
    const q=project(centerOnSubject||s.center),sel=s.id===(hoverSector??selectedSector),col=routeMode==='all'?'#8b96a6':colorForDelta(s.delta);
    markerRows.push({s,q,sel,col});
    x.save();if(sel){x.beginPath();x.arc(q[0],q[1],14,0,Math.PI*2);x.fillStyle='rgba(15,23,42,.10)';x.fill()}x.beginPath();x.arc(q[0],q[1],10,0,Math.PI*2);x.fillStyle='#fff';x.fill();x.strokeStyle=col;x.lineWidth=2;x.stroke();x.fillStyle='#334155';x.textAlign='center';x.textBaseline='middle';x.font='700 10px system-ui,sans-serif';x.fillText(String(s.id),q[0],q[1]+.5);x.restore();c._hits.push({id:s.id,q});
  }
  if(routeMode!=='all'){
    const occupied=markerRows.map(r=>({x:r.q[0]-12,y:r.q[1]-12,w:24,h:24}));occupied.push(...screenOverlayRects($('route')));const routePoints=[...routeScreenSamples(subjectTrack,project),...routeScreenSamples(referenceTrack,project)];
    for(const row of markerRows){const s=row.s;if(s.delta==null)continue;const dv=timeDeltaView(s.delta,s.subjectEndpointApprox||s.referenceEndpointApprox),tangent=screenTangentAt(subjectTrack,s.centerS,project),place=chooseSectorLabel(x,row.q,dv.marker,w,h,occupied,routePoints,tangent);if(!place)continue;
      x.save();x.textAlign='center';x.textBaseline='middle';x.font='700 11px system-ui,sans-serif';x.lineJoin='round';x.strokeStyle='rgba(255,255,255,.96)';x.lineWidth=4;x.strokeText(dv.marker,place.x,place.y);x.fillStyle=row.col;x.fillText(dv.marker,place.x,place.y);x.restore();occupied.push(place.rect);
    }
  }
  $('zoomText').textContent=Math.round(view.zoom*100)+'%';
  const gid=gameIdOf(analysis),modeText=routeMode==='drift'?'仅漂移':routeMode==='recovery'?'起漂→恢复结束':routeMode==='custom'?'自定义路径':'全部路线';
  let rule=routeMode==='all'?'不计算区段时间':routeMode==='drift'?'仅在双方该位置都存在唯一 Drift 时比较 Drift 时间':routeMode==='recovery'?'地图显示最终净时间差：核心到较早恢复终点，最终继续到较晚恢复终点；额外单/双喷阶段作为恢复收益单独分解':'A 手选唯一空间起终点；B 只测经过相同世界坐标区间的真实时间';
  if(visual){const src=visual.source==='same-name'?'同名已解析录像提供的官方底图':'官方 map.nif 底图';$('mapNote').textContent=`${src} · ${modeText} · ${rule}。A 蓝线=当前圈${referenceTrack?'，B 橙线=对比圈':''}。`;}
  else if(gid){$('mapNote').textContent=`Game ${gid} 已识别但官方底图未确认 · ${modeText} · ${rule}；同 GameID 或同名地图录像仍可比较。`;}
  else{$('mapNote').textContent=`官方底图不可用 · ${modeText} · ${rule}；同名地图录像仍可比较。`;}
}
function hitSector(e){const c=$('route'),r=c.getBoundingClientRect(),px=e.clientX-r.left,py=e.clientY-r.top;let best=null,bd=Infinity;for(const h of c._hits||[]){const d=Math.hypot(px-h.q[0],py-h.q[1]);if(d<bd){bd=d;best=h}}return bd<=24?best:null}
function renderComparisonBreakdown(s){
  const box=$('comparisonBreakdown'),core=$('coreDelta'),gain=$('recoveryGain');if(!box||!core||!gain)return;
  if(routeMode!=='recovery'||!s||s.coreDelta==null||!s.finalResultAvailable){box.classList.add('hidden');core.textContent='—';gain.textContent='—';core.className='';gain.className='';return}
  const cv=timeDeltaView(s.coreDelta,s.subjectEndpointApprox||s.referenceEndpointApprox),gv=recoveryGainView(s.recoveryGain);
  core.textContent=cv.text;core.className=cv.state;gain.textContent=gv.text;gain.className=gv.state;box.classList.remove('hidden');
}

function renderInspector(){
  const id=hoverSector??selectedSector,s=sectors.find(x=>x.id===id),hero=$('deltaHero'),label=$('sectorDeltaLabel');
  label.textContent=routeMode==='drift'?'仅漂移':routeMode==='recovery'?'最终净结果':'区段对比';
  if(!s){renderComparisonBreakdown(null);clearSectorMetrics();$('sectorTitle').textContent='—';$('sectorIndex').textContent='—';$('sectorDelta').textContent='—';$('subjectTime').textContent='—';$('referenceTime').textContent='—';hero.className='deltaHero neutral';if(routeMode==='all')$('sectorDirection').textContent='全部路线模式不判断时间';else $('sectorDirection').textContent=compareFile?'选择地图上的漂移编号':'先选择对比对象';return}
  $('sectorTitle').textContent=`漂移 ${s.id}`;$('sectorIndex').textContent=s.id;
  if(routeMode==='all'){
    renderComparisonBreakdown(null);clearSectorMetrics();$('sectorDelta').textContent='—';$('sectorDirection').textContent='全部路线模式只显示轨迹，不计算区段时间';$('subjectTime').textContent='—';$('referenceTime').textContent='—';hero.className='deltaHero neutral';$('sectorNote').textContent='当前编号仍由 Native Drift 定位，但“全部路线”只用于看完整轨迹。切换到“仅漂移”或“起漂→恢复结束”后才计算时间。';return;
  }
  renderComparisonBreakdown(s);
  const fmtModeTime=(v,approx)=>v==null?'—':`${approx?'≈':''}${fmt(v,3)}s`;
  $('subjectTime').textContent=fmtModeTime(s.subjectTime,s.subjectEndpointApprox);$('referenceTime').textContent=fmtModeTime(s.referenceTime,s.referenceEndpointApprox);
  if(s.delta==null){
    $('sectorDelta').textContent='—';hero.className='deltaHero neutral';
    if(!compareFile)$('sectorDirection').textContent='当前未选择对比对象';
    else if(routeMode==='drift'&&s.referenceDriftStatus==='none')$('sectorDirection').textContent='对比侧该位置未漂移，不做 Drift 时间硬比较';
    else if(routeMode==='drift'&&s.referenceDriftStatus==='ambiguous')$('sectorDirection').textContent='对比侧该位置存在多个独立 Drift，当前不强行配对';
    else if(compareFile&&s.mappingStatus&&s.mappingStatus!=='ready')$('sectorDirection').textContent=s.mappingStatus==='ambiguous'?'该位置存在多个可能的空间对应，已拒绝误比较':'该位置空间对应不够可靠，已跳过比较';
    else $('sectorDirection').textContent='当前没有可靠的可比时间';
  }else{
    const dv=timeDeltaView(s.delta,s.subjectEndpointApprox||s.referenceEndpointApprox);$('sectorDelta').textContent=dv.text;$('sectorDirection').textContent=dv.direction;hero.className='deltaHero '+dv.state;
  }
  if(routeMode==='drift'){
    $('sectorNote').textContent=s.referenceDriftStatus==='unique'?'“仅漂移”只比较双方在同一空间位置唯一对应的 Native Drift 时间；相邻 Drift gap < 0.15s 仍按一个 UI 段处理。':s.referenceDriftStatus==='none'?'对比侧经过同一位置但没有 Native Drift：这里只陈述“未漂移”，不把非漂移通过时间冒充 Drift 时间。':'对比侧同一位置出现多个独立 Drift：本模式暂不强配。';
  }else{
    if(s.delta!=null){
      const side='最终净结果：从共同起漂边界比较到较晚的自然恢复终点；“核心弯道”仍在较早恢复终点截止，“恢复收益”表示随后单/双喷策略让 A-B 时间差改变了多少。';
      $('sectorNote').textContent=side+(s.subjectEndpointApprox||s.referenceEndpointApprox?' ≈ 表示最终区间被下一次独立起漂截断。':'');
    }else if(!s.recoveryAvailable){$('sectorNote').textContent='当前侧没有 native 小喷恢复尾段时，核心时间最多比较到该侧 Drift end；不会借用另一侧更长的喷气尾段来扩大主时间区间。';}
    else{$('sectorNote').textContent='当前没有形成双方共同的可比恢复区间；不会退回“各算各的区间”或跨到邻近路段。';}
  }
  renderSectorMetrics(s);
  setTimeout(clampInspectorPosition,0);
}

function updateRouteModeButtons(){for(const b of document.querySelectorAll('[data-route-mode]'))b.classList.toggle('active',b.dataset.routeMode===routeMode)}
for(const b of document.querySelectorAll('[data-route-mode]'))b.onclick=()=>{routeMode=b.dataset.routeMode;updateRouteModeButtons();$('clearCustomPath')?.classList.toggle('hidden',routeMode!=='custom');renderAll()};
$('clearCustomPath').onclick=()=>{resetCustomPath();renderAll()};
updateRouteModeButtons();$('clearCustomPath')?.classList.toggle('hidden',routeMode!=='custom');

$('search').oninput=renderList;
$('uploadBtn').onclick=()=>$('fileInput').click();
$('fileInput').onchange=async e=>{try{for(const f of e.target.files||[]){$('topState').textContent='分析 '+f.name+'...';const r=await fetch('/api/analyze-upload?name_b64='+encodeURIComponent(enc(f.name)),{method:'POST',body:await f.arrayBuffer()});const t=await r.text();if(!r.ok)throw new Error(t)}telemetryCache.clear();analysisCache.clear();mapCache.clear();imageCache.clear();invalidateViewModel();await loadList();$('topState').textContent='分析完成'}catch(ex){err(ex.message)}finally{e.target.value=''}};
$('route').onmousemove=e=>{
  const subjectTrack=getSubjectTrack(),referenceTrack=getReferenceTrack();
  if(routeMode==='custom'&&customPath.dragHandle){
    const key=customPath.dragHandle,track=subjectTrack;if(!track)return;const idx=nearestTrackIndexScreen(e,track,80);if(idx==null)return;
    if(key.endsWith('StartIdx')){const end=customPath[key.replace('StartIdx','EndIdx')];customPath[key]=Number.isInteger(end)?Math.min(idx,end-1):idx}else{const st=customPath[key.replace('EndIdx','StartIdx')];customPath[key]=Number.isInteger(st)?Math.max(idx,st+1):idx}
    if(referenceTrack&&customSubjectReady())autoMapCustomReference(subjectTrack,referenceTrack);renderAll();return;
  }
  if(view.drag){const dx=e.clientX-view.x,dy=e.clientY-view.y;if(Math.abs(dx)+Math.abs(dy)>1)view.moved=true;view.panX+=dx;view.panY+=dy;view.x=e.clientX;view.y=e.clientY;redrawCanvas();return}
  if(routeMode==='custom')return;
  const h=hitSector(e),id=h?.id??null;if(id!==hoverSector){hoverSector=id;redrawCanvas();renderInspector()}
};
$('route').onmouseleave=()=>{if(routeMode!=='custom'&&!view.drag&&hoverSector!=null){hoverSector=null;redrawCanvas();renderInspector()}};
$('route').onmousedown=e=>{
  if(routeMode==='custom'){const h=hitCustomHandle(e);if(h){customPath.dragHandle=h.key;view.drag=false;view.moved=false;return}
    const subjectTrack=getSubjectTrack(),referenceTrack=getReferenceTrack();if(!customSubjectReady()){const idx=nearestTrackIndexScreen(e,subjectTrack,24);if(idx!=null){if(!Number.isInteger(customPath.subjectStartIdx))customPath.subjectStartIdx=idx;else{let a=customPath.subjectStartIdx,b=idx;if(b<a){const t=a;a=b;b=t}if(b>a){customPath.subjectStartIdx=a;customPath.subjectEndIdx=b;if(referenceTrack)autoMapCustomReference(subjectTrack,referenceTrack)}}renderAll();return}}
  }
  view.drag=true;view.moved=false;view.x=e.clientX;view.y=e.clientY
};
$('route').onmouseup=e=>{
  if(customPath.dragHandle){customPath.dragHandle=null;renderAll();return}
  if(routeMode!=='custom'){const h=hitSector(e);if(!view.moved&&h){selectedSector=h.id;hoverSector=null;redrawCanvas();renderInspector()}}
  view.drag=false;view.moved=false
};window.onmouseup=()=>{customPath.dragHandle=null;view.drag=false;view.moved=false};
$('mapWrap').onwheel=e=>{
  e.preventDefault();const c=$('route'),r=c.getBoundingClientRect(),oldZoom=view.zoom,newZoom=Math.max(.35,Math.min(7,oldZoom*(e.deltaY<0?1.12:.89)));if(newZoom===oldZoom)return;
  const mx=e.clientX-r.left,my=e.clientY-r.top,cx=r.width/2,cy=r.height/2,ratio=newZoom/oldZoom;
  view.panX=mx-cx-(mx-cx-view.panX)*ratio;view.panY=my-cy-(my-cy-view.panY)*ratio;view.zoom=newZoom;redrawCanvas();
};$('zoomIn').onclick=()=>{view.zoom=Math.min(7,view.zoom*1.2);redrawCanvas()};$('zoomOut').onclick=()=>{view.zoom=Math.max(.35,view.zoom/1.2);redrawCanvas()};$('resetView').onclick=()=>{view.zoom=1;view.panX=0;view.panY=0;redrawCanvas()};window.onresize=()=>{fitMapViewportHeight();clampInspectorPosition();if(analysis)redrawCanvas()};


$('sideToggle').onclick=e=>{e?.stopPropagation?.();setReplayRailCollapsed(!replayRailCollapsed)};
$('inspectorToggle').onclick=e=>{e?.stopPropagation?.();setInspectorCollapsed(!inspectorCollapsed)};
$('inspectorDragHandle').onmousedown=e=>{
  if(e?.target?.closest?.('#inspectorToggle'))return;const panel=$('inspectorPanel');if(!panel)return;
  const r=panel.getBoundingClientRect();inspectorDrag={dx:e.clientX-r.left,dy:e.clientY-r.top};inspectorUserMoved=true;e.preventDefault?.();e.stopPropagation?.();
};
document.addEventListener('mousemove',e=>{
  if(!inspectorDrag)return;const wrap=$('mapWrap');if(!wrap)return;const r=wrap.getBoundingClientRect();
  inspectorPos.x=e.clientX-r.left-inspectorDrag.dx;inspectorPos.y=e.clientY-r.top-inspectorDrag.dy;clampInspectorPosition();
});
document.addEventListener('mouseup',()=>{inspectorDrag=null});
// Always start with the current-segment overlay expanded. Collapse is session-local UI state only.
inspectorCollapsed=false;$('inspectorPanel')?.classList.remove('collapsed');
setInspectorCollapsed(false);setReplayRailCollapsed(false);fitMapViewportHeight();clampInspectorPosition();

$('settingsBtn').onclick=async()=>{$('settings').classList.remove('hidden');await loadSystem()};$('closeSettings').onclick=()=>$('settings').classList.add('hidden');
function applySystemStatus(j){
  systemStatus=j||{};const boot=j?.bootstrap||{},ready=!!boot.ready,task=String(boot.task_id||''),upload=$('uploadBtn');
  $('gamePath').value=j?.game_path||'';
  if(upload){upload.disabled=!j?.game_path_valid||!ready;upload.title=!j?.game_path_valid?'请先在设置中选择 QQ飞车 游戏目录':(!ready?'游戏资料正在首次初始化':'添加 .sav 录像')}
  const state=ready?'已就绪':(task?'初始化中':'待初始化');
  $('sysInfo').textContent=`游戏资料 ${state} · 官方地图 ${j?.catalog_maps||0} · 已生成 NativeMap ${j?.native_map_count||0} · 分析 ${j?.analyses||0}`;
  if(task&&task!==bootstrapPollTaskId)ensureCatalogTaskMonitor(task).catch(e=>err(e.message));
  return j;
}
async function loadSystem(){return applySystemStatus(await json('/api/system-status?x='+Date.now()))}
function ensureCatalogTaskMonitor(id){
  id=String(id||'');if(!id)return Promise.resolve(null);if(bootstrapPollTaskId===id&&bootstrapPollPromise)return bootstrapPollPromise;
  bootstrapPollTaskId=id;
  bootstrapPollPromise=(async()=>{
    while(true){
      await new Promise(r=>setTimeout(r,800));
      const j=await json('/api/tool-task-status?id='+encodeURIComponent(id)+'&x='+Date.now()),lines=(j.log||[]);
      $('topState').textContent=j.done?(j.ok?'游戏资料已就绪':'游戏资料初始化失败'):`游戏资料初始化中 · ${j.elapsed_s??0}s`;
      $('settingsLog').textContent=lines.slice(-120).join('\n')||$('topState').textContent;
      if(j.done){if(!j.ok)throw new Error(lines.slice(-80).join('\n')+'\n'+(j.error||''));break}
    }
    return await loadSystem();
  })().finally(()=>{if(bootstrapPollTaskId===id){bootstrapPollTaskId='';bootstrapPollPromise=null}});
  return bootstrapPollPromise;
}
async function acceptGamePathResult(j){
  if(!j||j.cancelled)return loadSystem();
  if(j.game_path)$('gamePath').value=j.game_path;
  const task=String(j.bootstrap?.task_id||'');
  if(task)ensureCatalogTaskMonitor(task).catch(e=>err(e.message));
  return loadSystem();
}
$('browseGame').onclick=async()=>{try{await acceptGamePathResult(await post('/api/settings/select-game-path',{}))}catch(e){err(e.message)}};
$('saveGame').onclick=async()=>{try{await acceptGamePathResult(await post('/api/settings/game-path',{path:$('gamePath').value}))}catch(e){err(e.message)}};
$('rebuildCatalog').onclick=async()=>{const b=$('rebuildCatalog');b.disabled=true;$('settingsLog').textContent='重新初始化游戏资料...';try{const j=await post('/api/map-tool',{action:'rebuild_catalog'});if(!j.ok)throw new Error(j.error||'失败');if(j.task_id)await ensureCatalogTaskMonitor(j.task_id);else await loadSystem()}catch(e){err(e.message)}finally{b.disabled=false}};
$('clearDerived').onclick=async()=>{if(!confirm('清空所有分析缓存？原始录像、用户标签和设置会保留。'))return;await post('/api/clear-runtime-cache',{});telemetryCache.clear();analysisCache.clear();mapCache.clear();imageCache.clear();invalidateViewModel();currentFile='';await loadList();await loadSystem()};
$('refreshBtn').onclick=async()=>{const b=$('refreshBtn');b.disabled=true;try{const st=await post('/api/refresh-data-start',{});while(true){await new Promise(r=>setTimeout(r,800));const j=await json('/api/tool-task-status?id='+encodeURIComponent(st.task_id)+'&x='+Date.now());$('topState').textContent=j.done?(j.ok?'重新分析完成':'重新分析失败'):`重新分析中 · ${j.elapsed_s??0}s`;if(j.done){if(!j.ok)throw new Error((j.log||[]).slice(-80).join('\n')+'\n'+(j.error||''));break}}telemetryCache.clear();analysisCache.clear();mapCache.clear();imageCache.clear();invalidateViewModel();await loadList(currentFile)}catch(e){err(e.message)}finally{b.disabled=false}};

async function initializeFrontend(){
  const st=await loadSystem();
  if(!st?.game_path_valid)$('settings').classList.remove('hidden');
  await loadList();
}
initializeFrontend().catch(e=>err(e.message));
