// Frontend segment/comparison contract regression (Node, no browser).
//
// `Modules/Frontend/js/app.js` is a plain script whose functions are the product contract: the
// automatic segment list, the recovery end, the A/B numbers and the analysis-vs-redraw split. This
// harness evaluates the REAL source in a vm context with a minimal DOM/canvas stub and exercises it,
// so a broken contract fails the gate instead of reaching the page as a runtime toast.
//
// Contract assertions:
//   T1  a published segment keeps every normalized field through driftSectorDefinition
//   T2  the recovery end comes from the PUBLISHED contract and the legacy inference is not called
//   T3  no `Cannot read properties of undefined (reading 'start_t')` for any segment
//   T4  an analysis without the published contract still works (compatibility path)
//   T5  drift mode with a real comparison target does not throw (latent scope bug)
//   T6  pan / zoom / hover / selection never rebuild the analysis view model
//   T7  a data change DOES rebuild it
//   T8  with the published comparison contract loaded, the browser correspondence is not recomputed
//   T9  UI timing deltas say 快/慢 explicitly and never require interpreting a +/- sign
//   T10 replay display names remove a redundant map-name prefix without mutating the source name
//   T11 map result labels choose an off-route, non-overlapping placement when space exists
//   T12 layout-only collapse/viewport controls do not rebuild analysis
//   T13 speed metrics use the refined field-calibrated 2026 SAV -> QQ Speed HUD coefficient (15.4) and integer presentation
//   T14 paired recovery fallback keeps earlier entry but caps primary time at the earlier natural recovery end
//   T15 final/core/recovery decomposition keeps the published final-net result authoritative
//   T16 first-run status gates Add Replay until game-path bootstrap is ready
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {fileURLToPath} from 'node:url';

const here=path.dirname(fileURLToPath(import.meta.url));
const appDir=path.resolve(here,'..','..');                 // Data\App
const appJs=path.join(appDir,'Modules','Frontend','js','app.js');
const source=fs.readFileSync(appJs,'utf8');

let failures=0;
function check(ok,label,detail){
  if(ok){ console.log('  [ok] '+label); return; }
  failures++;
  console.log('  [FAIL] '+label+(detail!==undefined?(' :: '+detail):''));
}
function section(t){ console.log('\n'+t); }

// --- minimal DOM / canvas stub ---------------------------------------------------------------
function makeCtx(){
  return new Proxy({},{
    get(t,p){ if(p in t)return t[p]; return ()=>{}; },
    set(t,p,v){ t[p]=v; return true; }
  });
}
function makeElement(tag='div'){
  const el={
    tagName:String(tag).toUpperCase(),_tag:String(tag),children:[],
    textContent:'',innerHTML:'',value:'',disabled:false,checked:false,hidden:false,
    style:{},dataset:{},width:0,height:0,_ctx:null,_project:null,_hits:[],_customHandles:[],
    classList:{_s:new Set(),add(...c){c.forEach(x=>this._s.add(x))},remove(...c){c.forEach(x=>this._s.delete(x))},
      toggle(c,f){const on=(f===undefined)?!this._s.has(c):!!f;if(on)this._s.add(c);else this._s.delete(c);return on},
      contains(c){return this._s.has(c)}},
    appendChild(c){this.children.push(c);return c},
    removeChild(c){this.children=this.children.filter(x=>x!==c);return c},
    querySelector(){return makeElement('div')},
    querySelectorAll(){return []},
    closest(){return null},
    addEventListener(){},
    removeEventListener(){},
    setAttribute(){},getAttribute(){return null},
    focus(){},click(){},
    getBoundingClientRect(){return{left:0,top:0,width:800,height:600,right:800,bottom:600}},
    getContext(){ if(!this._ctx)this._ctx=makeCtx(); return this._ctx },
    insertBefore(){},remove(){}
  };
  return el;
}
const elements=new Map();
const routeModes=['all','recovery','custom'].map(m=>{const b=makeElement('button');b.dataset.routeMode=m;return b});
const document={
  getElementById(id){ if(!elements.has(id))elements.set(id,makeElement('div')); return elements.get(id) },
  createElement(tag){ return makeElement(tag) },
  querySelectorAll(sel){ return sel==='[data-route-mode]'?routeModes:[] },
  querySelector(){ return makeElement('div') },
  body:makeElement('body'),
  addEventListener(){}
};
const window={
  devicePixelRatio:1,
  addEventListener(){},
  onmouseup:null,onresize:null,
  location:{href:'http://127.0.0.1/'}
};
const sandbox={
  document,window,console,
  setTimeout,clearTimeout,
  btoa:s=>Buffer.from(s,'binary').toString('base64'),
  atob:s=>Buffer.from(s,'base64').toString('binary'),
  escape,unescape,encodeURIComponent,decodeURIComponent,
  Math,Number,JSON,Date,Object,Array,String,Boolean,Promise,Set,Map,Error,Infinity,NaN,isFinite,parseFloat,parseInt,
  Image:class{ set src(v){} },
  fetch:()=>Promise.resolve({ok:true,status:200,text:()=>Promise.resolve('[]')})
};
sandbox.globalThis=sandbox;
const ctx=vm.createContext(sandbox);
vm.runInContext(source,ctx,{filename:appJs});

// --- in-context helpers ----------------------------------------------------------------------
vm.runInContext(`
  __t={calls:{drawRoute:0,mapBoundaries:0,buildTrack:0,exitSmallBoost:0,sharedRecoveryWindow:0,compareDriftMatch:0}};
  (function(){
    const _d=drawRoute; drawRoute=function(){__t.calls.drawRoute++;return _d.apply(null,arguments)};
    const _m=mapBoundaries; mapBoundaries=function(){__t.calls.mapBoundaries++;return _m.apply(null,arguments)};
    const _b=buildTrack; buildTrack=function(){__t.calls.buildTrack++;return _b.apply(null,arguments)};
    const _e=exitSmallBoostEndpoint; exitSmallBoostEndpoint=function(){__t.calls.exitSmallBoost++;return _e.apply(null,arguments)};
    const _s=sharedRecoveryWindow; sharedRecoveryWindow=function(){__t.calls.sharedRecoveryWindow++;return _s.apply(null,arguments)};
    const _c=compareDriftMatch; compareDriftMatch=function(){__t.calls.compareDriftMatch++;return _c.apply(null,arguments)};
  })();
  post=function(){return new Promise(function(){})};
  json=function(){return Promise.resolve([])};
  defineCompareTarget=function(){compareFile='synth2.sav';compareLap='1';compareInternalStreamId=''};
  clearCompareTarget=function(){compareFile='';compareLap='';compareInternalStreamId=''};
`,ctx);

// --- synthetic replay ------------------------------------------------------------------------
// A closed loop so the projection produces a real 2D track; 300 samples over 30 s.
vm.runInContext(`
  function __mkPoints(n,loop,phase){
    const out=[];
    for(let i=0;i<=n;i++){
      const u=2*Math.PI*(i/n);
      out.push({t:(i/n)*30,x:100*Math.cos(u+phase),y:loop?60*Math.sin(u+phase):40*Math.sin(u+phase),
        break_before:false,speed:10+2*Math.sin(u)});
    }
    return out;
  }
  const __streamLocal={id:'shadow_local',role:'local_high_frequency',sample_hz:60,duration_s:30,
    laps:[{lap:1,start_t:0,end_t:30,duration_s:30}],preview:__mkPoints(300,false,0)};
  const __streamCompare={id:'shadow_local',role:'local_high_frequency',sample_hz:60,duration_s:30,
    laps:[{lap:1,start_t:0,end_t:30,duration_s:30}],preview:__mkPoints(300,false,0.05)};
  function __mkAnalysis(withContract){
    const a={schema_version:29,contract:'native_first_analysis_v1',map_name:'SYNTH',replay_file:'synth.sav',
      resource_map_id:900,game_map_id:900,native_map:{status:'unavailable'},
      telemetry_summary:'',driving_episodes:{streams:[{id:'shadow_local',role:'local_high_frequency',
        laps:[{lap:1,episodes:[
          {id:'L1-D01',lap:1,time:{start_t:4.0,end_t:6.0,duration_s:2.0}},
          {id:'L1-D02',lap:1,time:{start_t:12.0,end_t:13.0,duration_s:1.0}}
        ]}]}]}};
    if(withContract){
      a.segment_analysis={schema_version:2,contract:'native_analysis_segments_v1',status:'ready',
        streams:[{id:'shadow_local',role:'local_high_frequency',status:'ready',segment_count:3,
          laps:[{lap:1,segment_count:3,segments:[
            {segment_index:1,lap_owner:1,drift_count:1,start_t:4.0,drift_end_t:6.0,drift_duration_s:2.0,
             recovery_available:true,recovery_end_t:6.9,recovery_stop_reason:'native_small_boost_end',
             next_drift_start_t:12.0,drift_intervals:[{start_t:4.0,end_t:6.0}]},
            {segment_index:2,lap_owner:1,drift_count:2,start_t:12.0,drift_end_t:14.0,drift_duration_s:2.0,
             recovery_available:false,recovery_end_t:14.0,recovery_stop_reason:'no_native_recovery_effect',
             next_drift_start_t:22.0,drift_intervals:[{start_t:12.0,end_t:13.0},{start_t:13.05,end_t:14.0}]},
            {segment_index:3,lap_owner:1,drift_count:1,start_t:22.0,drift_end_t:24.0,drift_duration_s:2.0,
             recovery_available:true,recovery_end_t:28.0,recovery_stop_reason:'next_drift_hard_cut',
             next_drift_start_t:null,drift_intervals:[{start_t:22.0,end_t:24.0}]}
          ]}]
        }]};
    }
    return a;
  }
  analysis=__mkAnalysis(true);
  stream=__streamLocal;
  compareAnalysis=__mkAnalysis(true);
  compareStream=__streamCompare;
  records=[{file:'synth.sav',replay:'synth.sav',map:'SYNTH',streams:[{id:'shadow_local',role:'local_high_frequency'}],native_map_status:'unavailable'}];
  currentFile='synth.sav';currentLap='1';compareFile='';compareLap='';compareInternalStreamId='';
  routeMode='recovery';selectedSector=null;hoverSector=null;
  resetCustomPath();
  invalidateViewModel();
`,ctx);

// --- T1..T3: published segment contract -------------------------------------------------------
section('published segment contract (T1-T3)');
vm.runInContext(`
  const __track=buildTrack(lapView(stream,currentLap,routeViewEndT(analysis,stream,currentLap)));
  const __defs=driftSectorDefinition(__track,analysis,currentLap,stream);
  const __rec=recoverySectorDefinition(__track,analysis,currentLap,stream);
  __t.defs=__defs;__t.rec=__rec;__t.track=__track;
  __t.normalizedFields=__defs.map(d=>({server:d.server,hasTime:!!(d.time&&Number.isFinite(d.time.start_t)),
    startT:d.startT,driftEndT:d.driftEndT,recoveryEndT:d.serverRecoveryEndT,reason:d.serverRecoveryReason,
    driftCount:d.driftCount,lapOwner:d.lapOwner}));
  __t.recCalls=__t.calls.exitSmallBoost;
`,ctx);
const norm=vm.runInContext('__t.normalizedFields',ctx);
check(norm.length===3,'driftSectorDefinition produced three segments',JSON.stringify(norm.length));
check(norm.every(n=>n.server===true),'every segment is marked as published');
check(norm.every(n=>n.hasTime===true),'every normalized segment keeps time.start_t');
check(norm.every(n=>Number.isFinite(n.startT)&&Number.isFinite(n.driftEndT)),'every normalized segment keeps start/drift-end native times');
check(norm[0].reason==='native_small_boost_end'&&norm[1].reason==='no_native_recovery_effect'&&norm[2].reason==='next_drift_hard_cut','recovery reasons survive normalization',JSON.stringify(norm.map(n=>n.reason)));
check(norm[1].driftCount===2,'merged segment keeps drift_count',String(norm[1].driftCount));
const rec=vm.runInContext('__t.rec',ctx);
check(rec.length===3,'recoverySectorDefinition returned every segment (no throw)');
check(rec.every(r=>r.recoveryEndIdx!=null),'every recovery segment has a drawn end index');
check(rec[0].nativeRecoveryEndT===6.9&&rec[0].recoverySource==='published_contract','segment 1 recovery end comes from the published contract',JSON.stringify(rec[0].nativeRecoveryEndT));
check(rec[1].recoveryAvailable===false&&rec[1].recoveryEndIdx===rec[1].subjectEndIdx,'segment 2 with no native recovery effect stays at its Drift end');
check(rec[2].recoveryInterrupted===true,'segment 3 is flagged as a next-Drift hard cut');
check(rec[2].nativeRecoveryEndT===28.0,'segment 3 keeps the published hard-cut time');
check(vm.runInContext('__t.recCalls',ctx)===0,'the legacy in-browser recovery inference was never called for published segments');

// --- T4: compatibility path (analysis without the published contract) -------------------------
section('compatibility path without the published contract (T4)');
vm.runInContext(`
  analysis=__mkAnalysis(false);
  invalidateViewModel();
  const __track2=buildTrack(lapView(stream,currentLap,routeViewEndT(analysis,stream,currentLap)));
  __t.legacyDefs=driftSectorDefinition(__track2,analysis,currentLap,stream);
  __t.legacyRec=recoverySectorDefinition(__track2,analysis,currentLap,stream);
  __t.legacyFields=__t.legacyDefs.map(d=>({server:d.server,hasTime:!!(d.time&&Number.isFinite(d.time.start_t)),id:d.id}));
  __t.legacyCalls=__t.calls.exitSmallBoost;
`,ctx);
const legacy=vm.runInContext('__t.legacyFields',ctx);
check(legacy.length===2,'the compatibility path produced the merged episode list',JSON.stringify(legacy.length));
check(legacy.every(l=>l.server===false&&l.hasTime===true),'compatibility segments are marked server:false and still carry time');
check(vm.runInContext('__t.legacyRec.length',ctx)===2,'the compatibility recovery path returned every segment (no throw)');
check(vm.runInContext('__t.legacyCalls',ctx)>0,'the compatibility path does use the in-browser inference (only when no contract exists)');

// --- T5: drift mode with a real comparison target ---------------------------------------------
section('drift mode with a comparison target (T5)');
vm.runInContext(`
  analysis=__mkAnalysis(true);
  invalidateViewModel();
  routeMode='drift';compareFile='';compareLap='';
  __t.driftThrew=false;__t.driftSectors=null;
  try{
    const tk=buildTrack(lapView(stream,currentLap,routeViewEndT(analysis,stream,currentLap)));
    const rk=buildTrack(lapView(compareStream,'1',routeViewEndT(compareAnalysis,compareStream,'1')));
    defineCompareTarget();
    const defs=driftSectorDefinition(tk,analysis,currentLap,stream);
    __t.driftSectors=sectorMetrics(tk,rk,defs);
  }catch(e){ __t.driftThrew=true; __t.driftError=String(e&&e.message||e) }
`,ctx);
check(vm.runInContext('__t.driftThrew',ctx)===false,'drift mode + real B did not throw',vm.runInContext('__t.driftError',ctx));
check(vm.runInContext('__t.driftSectors.length',ctx)===3,'drift mode produced one metric row per segment');

// --- T6: pan / zoom / hover / selection must not rebuild the analysis view model ---------------
section('visual-only interactions do not recompute analysis (T6)');
vm.runInContext(`
  routeMode='recovery';defineCompareTarget();serverComparison=null;comparisonRequestKey='';
  invalidateViewModel();
  renderAll();
  __t.rBaseline=viewRevision;
  __t.buildBaseline=__t.calls.buildTrack;
  __t.mbBaseline=__t.calls.mapBoundaries;
  __t.drawBaseline=__t.calls.drawRoute;
  view.drag=true;view.x=100;view.y=100;
  $('route').onmousemove({clientX:140,clientY:130});
  $('route').onmousemove({clientX:180,clientY:160});
  $('route').onmousemove({clientX:220,clientY:190});
  view.drag=false;
  $('mapWrap').onwheel({preventDefault(){},clientX:300,clientY:200,deltaY:-120});
  $('zoomIn').onclick();
  $('zoomOut').onclick();
  $('resetView').onclick();
  view.zoom=1;view.panX=0;view.panY=0;
  hoverSector=1;$('route').onmousemove({clientX:9999,clientY:9999});
  $('route').onmouseup({clientX:400,clientY:300});
  $('route').onmouseleave();
  __t.rAfterVisual=viewRevision;
  __t.buildAfterVisual=__t.calls.buildTrack;
  __t.mbAfterVisual=__t.calls.mapBoundaries;
  __t.drawAfterVisual=__t.calls.drawRoute;
`,ctx);
const rBase=vm.runInContext('__t.rBaseline',ctx),rAfter=vm.runInContext('__t.rAfterVisual',ctx);
check(rAfter===rBase,'pan/zoom/wheel/hover/selection performed ZERO view-model rebuilds',rBase+' -> '+rAfter);
check(vm.runInContext('__t.buildAfterVisual',ctx)===vm.runInContext('__t.buildBaseline',ctx),'no extra track build during visual interaction');
check(vm.runInContext('__t.mbAfterVisual',ctx)===vm.runInContext('__t.mbBaseline',ctx),'no extra spatial correspondence during visual interaction');
check(vm.runInContext('__t.drawAfterVisual',ctx)>vm.runInContext('__t.drawBaseline',ctx),'the canvas WAS redrawn during visual interaction');

// --- T7: a data change does rebuild -----------------------------------------------------------
section('data change rebuilds the view model (T7)');
vm.runInContext(`
  __t.rBeforeData=viewRevision;
  routeMode='drift';updateRouteModeButtons();renderAll();
  __t.rAfterData=viewRevision;
`,ctx);
check(vm.runInContext('__t.rAfterData',ctx)>vm.runInContext('__t.rBeforeData',ctx),'switching the route mode rebuilt the view model');

// --- T8: the published comparison contract suppresses the browser correspondence ---------------
section('published comparison contract is authoritative (T8)');
vm.runInContext(`
  routeMode='recovery';renderAll();
  const cmp={contract:'native_segment_comparison_v1',status:'ready',windows:[
    {window_id:'S01',status:'comparable',source:'paired_corner',corner_paired:true,
     corner:{subject_segment_index:1,baseline_segment_index:1,subject_start_t:4.0,baseline_start_t:4.0,
       subject_drift_end_t:6.0,baseline_drift_end_t:6.0,subject_recovery_end_t:6.9,baseline_recovery_end_t:6.8},
     space:{shared_start:.1,shared_end:.2,shared_span:.1,final_shared_end:.24,final_shared_span:.14,hard_cut_applied:false,final_hard_cut_applied:false,
       subject:{distance_m:40,start_distance_m:10,end_distance_m:50,start:{x:0,y:0},end:{x:1,y:0}},
       baseline:{distance_m:39,start_distance_m:10,end_distance_m:49,start:{x:0,y:0},end:{x:1,y:0}}},
     time:{subject_s:2.9,baseline_s:2.8,delta_s:.1,direction:'slower'},
     core_time:{subject_s:2.9,baseline_s:2.8,delta_s:.1,direction:'slower'},
     final_time:{subject_s:3.15,baseline_s:3.316,delta_s:-.166,direction:'faster',available:true},
     recovery_strategy:{subject_tail_s:.25,baseline_tail_s:.516,subject_net_gain_s:.266,direction:'subject_gain'},
     speed:{subject:{entry_mps:12,min_mps:10,exit_window_mps:14,average_mps:12},baseline:{entry_mps:12,min_mps:10,exit_window_mps:14,average_mps:12}},
     native:{subject:{segment_index:1,drift_count:1,drift_duration_s:2.0,drift_distance_m:40,recovery_distance_m:15,total_distance_m:55,exit_speed_mps:14,min_corner_speed_mps:10,recovery_end_t:6.9,recovery_end_reason:'native_small_boost_end',recovery_available:true},
             baseline:{segment_index:1,drift_count:1,drift_duration_s:2.0,drift_distance_m:39,recovery_distance_m:14,total_distance_m:53,exit_speed_mps:14,min_corner_speed_mps:10,recovery_end_t:6.8,recovery_end_reason:'native_small_boost_end',recovery_available:true}},
     metrics:[{id:'time_s',unit:'s',definition:'d',authority:'a',value:{subject:2.9,baseline:2.8,delta:.1,available:true}}]}
  ]};
  serverComparison={key:segmentComparisonKey(),comparison:cmp};
  invalidateViewModel();
  __t.mbBefore=__t.calls.mapBoundaries;__t.srwBefore=__t.calls.sharedRecoveryWindow;
  renderAll();
  __t.mbAfter=__t.calls.mapBoundaries;__t.srwAfter=__t.calls.sharedRecoveryWindow;
  __t.firstSector=sectors[0];
`,ctx);
check(vm.runInContext('__t.mbAfter',ctx)===vm.runInContext('__t.mbBefore',ctx),'no browser correspondence was computed while the published contract was loaded');
check(vm.runInContext('__t.srwAfter',ctx)===vm.runInContext('__t.srwBefore',ctx),'the browser shared-recovery window was not recomputed');
const first=vm.runInContext('__t.firstSector',ctx);
check(first&&Math.abs(Number(first.delta)+0.166)<1e-9,'recovery mode shows the published FINAL net delta on the map',JSON.stringify(first&&first.delta));
check(first&&Math.abs(Number(first.coreDelta)-0.1)<1e-9,'the sector retains the published core delta for decomposition',JSON.stringify(first&&first.coreDelta));
check(first&&Math.abs(Number(first.recoveryGain)-0.266)<1e-9,'the sector retains the published recovery-strategy gain',JSON.stringify(first&&first.recoveryGain));
check(first&&first.serverWindowId==='S01'&&Array.isArray(first.serverMetrics),'the sector carries the published window and metrics');
check(first&&first.referenceDisplayStartIdx!=null&&first.referenceDisplayEndIdx!=null,'the drawn reference range comes from the published native times');



// --- T9: presentation semantics are explicit ---------------------------------------------------
section('explicit UI delta semantics (T9)');
const fast=vm.runInContext('timeDeltaView(-0.121)',ctx);
const slow=vm.runInContext('timeDeltaView(0.238)',ctx);
const near=vm.runInContext('timeDeltaView(0.010)',ctx);
const tie=vm.runInContext('timeDeltaView(0)',ctx);
const missing=vm.runInContext('timeDeltaView(null)',ctx);
check(fast.state==='gain'&&fast.text==='快 0.121s'&&fast.marker==='快 0.121','negative A-B time is rendered explicitly as 快',JSON.stringify(fast));
check(slow.state==='loss'&&slow.text==='慢 0.238s'&&slow.marker==='慢 0.238','positive A-B time is rendered explicitly as 慢',JSON.stringify(slow));
check(near.state==='loss'&&near.text==='慢 0.010s','non-zero positive time is always rendered as 慢',JSON.stringify(near));
check(tie.state==='neutral'&&tie.text==='持平 0.000s','only exact zero is rendered as 持平',JSON.stringify(tie));
check(missing.text==='—','missing comparison stays unavailable instead of becoming 0.000s',JSON.stringify(missing));
check(!/[+-]0\./.test(fast.text+slow.text+near.text+tie.text),'primary delta wording contains no signed +/- time');

// --- T10: compact replay names ---------------------------------------------------------------
// Fixture names are anonymous on purpose: a real QQSpeed recording filename is
// `<map>-<date>-<time>-<nickname>.sav`, so copying one into the repository would publish a player
// nickname. The contract only needs the SHAPE (map prefix + timestamp + trailing label).
section('compact replay display names (T10)');
const shortA=vm.runInContext(`compactReplayLabel({map:'十一城',replay:'十一城-20260924-215054-测试车手.sav'})`,ctx);
const shortB=vm.runInContext(`compactReplayLabel({map:'十一城',display_name:'十一城 · 手动标签',replay:'十一城-x.sav'})`,ctx);
const keepC=vm.runInContext(`compactReplayLabel({map:'十一城',replay:'测试车手-练习.sav'})`,ctx);
check(shortA==='20260924-215054-测试车手','map prefix is removed from the ordinary replay filename',shortA);
check(shortB==='手动标签','map prefix is also removed from a redundant display alias',shortB);
check(keepC==='测试车手-练习','a non-prefixed replay label is preserved',keepC);

// --- T11: map label placement avoids the route/marker ----------------------------------------
section('map label placement avoidance (T11)');
vm.runInContext(`
  const __ctx={measureText:t=>({width:String(t).length*7})};
  const __occupied=[{x:88,y:88,w:24,h:24}];
  const __route=[];for(let x=20;x<=180;x+=4)__route.push([x,100]);
  __t.labelPlace=chooseSectorLabel(__ctx,[100,100],'慢 0.238',200,200,__occupied,__route,[1,0]);
  __t.labelHitsRoute=__route.some(p=>pointInRect(p,__t.labelPlace.rect,2));
  __t.labelHitsMarker=rectOverlap(__t.labelPlace.rect,__occupied[0],2);
`,ctx);
check(vm.runInContext('__t.labelPlace!=null',ctx),'a candidate label position was found');
check(vm.runInContext('__t.labelHitsRoute',ctx)===false,'label box avoids the nearby route when a clear side exists');
check(vm.runInContext('__t.labelHitsMarker',ctx)===false,'label box avoids the numbered sector marker');

// --- T12: layout controls stay visual-only ---------------------------------------------------
section('viewport / collapse controls are visual-only (T12)');
vm.runInContext(`
  __t.layoutRevBefore=viewRevision;
  __t.inspectorDefaultExpanded=!$('inspectorPanel').classList.contains('collapsed');
  setReplayRailCollapsed(true);
  setInspectorCollapsed(true);
  fitMapViewportHeight();
  __t.layoutRevAfter=viewRevision;
  __t.railCollapsed=$('shell').classList.contains('sideCollapsed');
  __t.inspectorCollapsed=$('inspectorPanel').classList.contains('collapsed');
  __t.mapHeight=String($('mapWrap').style.height||'');
`,ctx);
check(vm.runInContext('__t.inspectorDefaultExpanded',ctx)===true,'map inspector starts expanded by default');
check(vm.runInContext('__t.railCollapsed',ctx)===true,'replay rail can collapse');
check(vm.runInContext('__t.inspectorCollapsed',ctx)===true,'map inspector can collapse');
check(/px$/.test(vm.runInContext('__t.mapHeight',ctx)),'map height is fitted to the viewport',vm.runInContext('__t.mapHeight',ctx));
check(vm.runInContext('__t.layoutRevAfter',ctx)===vm.runInContext('__t.layoutRevBefore',ctx),'layout-only controls do not rebuild the analysis view model');


// --- T13: game HUD speed presentation ---------------------------------------------------------
section('QQ Speed HUD speed presentation (T13)');
check(vm.runInContext('GAME_SPEED_DISP_COEF',ctx)===15.4,'2026 SAV replay-to-HUD speed display coefficient is 15.4');
check(vm.runInContext('gameSpeedDisplay(17.384)',ctx)===267,'17.384 replay velocity displays as game HUD speed 267');
check(vm.runInContext("metricDisplayValue(METRIC_LABELS.entry_speed_mps,20.997)",ctx)==='323','speed metric uses integer game-HUD presentation');
check(vm.runInContext("METRIC_LABELS.entry_speed_mps[1]",ctx)==='km/h','speed metric is labelled km/h');

// --- T14: recovery compatibility path uses the core window ----------------------------------
section('paired recovery core window (T14)');
vm.runInContext(`
  __t.coreCandidate=chooseCoreComparableCandidate([
    {startA:10,startB:20,endA:80,endB:90,startProgress:.10,endProgress:.40,spanScore:.30,quality:1,signature:'long',endpointApprox:false},
    {startA:12,startB:22,endA:60,endB:70,startProgress:.12,endProgress:.28,spanScore:.16,quality:1,signature:'short',endpointApprox:false}
  ]);
`,ctx);
const coreCandidate=vm.runInContext('__t.coreCandidate',ctx);
check(coreCandidate.startA===10&&coreCandidate.startB===20,'core window keeps the earlier mapped Drift start',JSON.stringify(coreCandidate));
check(coreCandidate.endA===60&&coreCandidate.endB===70,'core window stops at the earlier natural recovery end',JSON.stringify(coreCandidate));
check(coreCandidate.source==='paired_core_window','compatibility path labels the core-window source',JSON.stringify(coreCandidate));

// --- T15: final/core/recovery decomposition --------------------------------------------------
section('final net result decomposition (T15)');
const rg=vm.runInContext('recoveryGainView(0.078)',ctx);
const rl=vm.runInContext('recoveryGainView(-0.031)',ctx);
check(rg.state==='gain'&&rg.text==='A 追回 0.078s','positive core-final improvement is rendered as A recovery gain',JSON.stringify(rg));
check(rl.state==='loss'&&rl.text==='A 损失 0.031s','negative core-final improvement is rendered as A recovery loss',JSON.stringify(rl));
check(first&&first.finalResultAvailable===true,'server final result is marked available');

// --- T16: first-run bootstrap gates replay import --------------------------------------------
section('first-run bootstrap UI gate (T16)');
vm.runInContext(`
  applySystemStatus({game_path:'',game_path_valid:false,catalog_maps:0,native_map_count:0,analyses:0,bootstrap:{ready:false,task_id:''}});
  __t.uploadNoPath={disabled:$('uploadBtn').disabled,title:$('uploadBtn').title,sys:$('sysInfo').textContent};
  applySystemStatus({game_path:'D:/QQSpeed',game_path_valid:true,catalog_maps:450,native_map_count:0,analyses:0,bootstrap:{ready:false,task_id:''}});
  __t.uploadNotReady={disabled:$('uploadBtn').disabled,title:$('uploadBtn').title,sys:$('sysInfo').textContent};
  applySystemStatus({game_path:'D:/QQSpeed',game_path_valid:true,catalog_maps:450,native_map_count:0,analyses:0,bootstrap:{ready:true,task_id:''}});
  __t.uploadReady={disabled:$('uploadBtn').disabled,title:$('uploadBtn').title,sys:$('sysInfo').textContent};
`,ctx);
const noPath=vm.runInContext('__t.uploadNoPath',ctx),notReady=vm.runInContext('__t.uploadNotReady',ctx),ready=vm.runInContext('__t.uploadReady',ctx);
check(noPath.disabled===true&&/游戏目录/.test(noPath.title),'Add Replay is disabled until a game path is selected',JSON.stringify(noPath));
check(notReady.disabled===true&&/初始化/.test(notReady.title),'Add Replay stays disabled while first-run game data is not ready',JSON.stringify(notReady));
check(ready.disabled===false&&/添加/.test(ready.title),'Add Replay is enabled when first-run game data is ready',JSON.stringify(ready));

console.log('\n'+(failures===0?'[OK] frontend segment/comparison contract passed.':'[FAILED] '+failures+' frontend contract assertion(s) failed.'));
process.exit(failures===0?0:1);
