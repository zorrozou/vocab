/* The coach owns its own view and evidence. Classic vocabulary state is never serialized here. */
window.VocabCoach = (() => {
  let screen='other', run=null, timer=null, expire=null, version=0, observer=false, selection='life';
  let availability=true;
  let lesson=null, feedback=false, textShown=false, plays=0, working=false, fault='', note='', modelNote='';
  const box=()=>document.getElementById('coachControls'), app=()=>document.getElementById('app');
  const key=()=> 'vocab.coach.mode.v1.'+(AUTH?.accountId || 'guest');
  const enabled=()=>localStorage.getItem(key())!=='classic';
  const active=()=>screen==='course'||screen==='practice';
  const uuid=()=>crypto.randomUUID?.() || 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,c=>((crypto.getRandomValues(new Uint8Array(1))[0]& (c==='x'?15:3))|(c==='x'?0:8)).toString(16));
  function node(tag,txt,cls) {
    const e=document.createElement(tag); if(txt)e.textContent=txt;if(cls)e.className=cls;return e;
  }
  function button(label,fn,primary=false) {
    const b=node('button',label,primary?'act':'icon'); b.onclick=fn;return b;
  }
  async function api(path,data,id,headers) {
    const res=await fetch(API+'/api/v1/coach/'+path,{method:'POST',cache:'no-store',
      headers:{...headers,'Content-Type':'application/json'},signal:AbortSignal.timeout(path==='explanation'?45000:9000),
      body:JSON.stringify({...data,client:id,offset:-new Date().getTimezoneOffset()})});
    if(!res.ok){const e=await res.json().catch(()=>({}));throw Error(typeof e.detail==='string'?e.detail:'无法连接教练');}
    return res.json();
  }
  function closed(){return active()&&(!run||performance.now()>=run.until);}
  function stop() {
    const old=run;run=null;version++;clearTimeout(timer);clearTimeout(expire);
    app().inert=false;
    if(old?.headers)api('clock',{action:'stop'},old.id,old.headers).catch(()=>{});
  }
  function classic() { stopAudio();stop();localStorage.setItem(key(),'classic');home(); }
  function leave() { stopAudio();stop();home(); }
  function switchPage(next) {
    if(screen!==next || (run && run.owner!==key())){stop();screen=next;fault='';note='';working=false;}
    box().hidden=screen==='other';
    if(box().hidden)return;
    if(!observer){observer=true;
      document.addEventListener('visibilitychange',()=>{if(!active())return;
        if(document.hidden){stopAudio();stop();app().inert=true;}else begin();});
      window.addEventListener('pagehide',()=>{if(run)stop();});
      window.addEventListener('pageshow',()=>{if(active()&&!document.hidden)begin();});
      for(const ev of ['click','keydown'])app().addEventListener(ev,e=>{
        if(closed()){e.preventDefault();e.stopImmediatePropagation();paintBar();}
      },true);
    }
    if(active()&&!run&&!document.hidden)begin();
    paintBar();
    if(next==='home')fetch(API+'/api/v1/coach/availability',{cache:'no-store',signal:AbortSignal.timeout(4000)}).then(async r=>{
      if(r.ok){const flag=(await r.json()).enabled;if(flag!==availability){availability=flag;if(screen==='home')paintBar();}}
    }).catch(()=>{});
  }
  async function begin() {
    if(run||!active()||document.hidden)return;
    const c={id:uuid(),owner:key(),until:0,snapshot:null,headers:null};run=c;fault='';
    app().inert=true;paintBar();
    try{c.headers=await personalHeaders();if(run!==c||key()!==c.owner)return;await pulse(c);}
    catch(e){if(run===c){fault=e.message;paintBar();}}
  }
  async function pulse(c,extend=false,offline=false) {
    if(run!==c||c.owner!==key()||document.hidden)return;
    try {
      if(extend)await api('clock',{action:'extend'},c.id,c.headers);
      const sent=performance.now(),snapshot=await api('clock',{action:offline?'offline':'pulse'},c.id,c.headers);
      if(run!==c||key()!==c.owner){api('clock',{action:'stop'},c.id,c.headers).catch(()=>{});return;}
      c.snapshot=snapshot;c.until=sent+snapshot.credit*1000;fault='';clearTimeout(timer);clearTimeout(expire);
      if(snapshot.busy)fault='另一台设备正在练习。请先在那里暂停，或稍后重试。';
      if(c.until>performance.now()){
        expire=setTimeout(()=>{if(run===c&&closed()){stopAudio();app().inert=true;paintBar();}},c.until-performance.now());
        timer=setTimeout(()=>pulse(c),Math.max(100,Math.min(10000,c.until-performance.now())));
        if(screen==='course'&&!lesson&&!working)loadLesson();
      }else if(snapshot.used<snapshot.limit)timer=setTimeout(()=>pulse(c),snapshot.busy?3000:500);
      paintBar();
    }catch(e){if(run===c){fault=e.message;paintBar();}}
  }
  function paintBar() {
    const host=box();host.replaceChildren();
    if(screen==='other'){host.hidden=true;return;}
    host.hidden=false;
    const panel=node('div','', 'card');host.append(panel);
    if(screen==='home') {
      if(!availability){host.hidden=true;return;}
      if(!enabled()){panel.append(node('small','经典词航 · 与教练课共用每日时间 '),button('开启听读教练',()=>{localStorage.setItem(key(),'on');paintBar();}));return;}
      panel.append(node('h2','今日教练课'),node('p','听一则消息，读懂变化，再决定怎样回应。约 3 分钟。'),
        node('p','听读与背词共用 30 分钟。到点默认收课，主动延长后最多 40 分钟。','muted'));
      const track=document.createElement('select');track.setAttribute('aria-label','课程场景');
      for(const [id,name] of [['life','日常生活'],['work','工作沟通']]){const o=node('option',name);o.value=id;track.append(o);}
      track.value=selection;track.onchange=()=>{selection=track.value;};
      panel.append(track,button(enabled()?'进入今日教练课':'启用教练并开始',()=>{
        localStorage.setItem(key(),'on');lesson=null;feedback=false;modelNote='';app().replaceChildren();switchPage('course');
      },true));
      if(enabled())panel.append(button('切回经典界面',classic));
      return;
    }
    const c=run,s=c?.snapshot,blocked=closed();app().inert=blocked;
    const spent=s?Math.min(s.limit,s.used+Math.max(0,Math.floor((s.credit*1000-(c.until-performance.now()))/1000))):0;
    panel.append(node('strong',s?'今日练习 '+Math.floor(spent/60)+' / '+s.limit/60+' 分钟':'正在核对今日练习时间…'));
    if(!blocked&&s&&s.limit-spent<=180)panel.append(node('p','剩余不到 3 分钟，建议做完手头这题就收课。','muted'));
    if(blocked){
      if(s&&s.used>=s.limit)panel.append(node('p',s.extended?'今天已到 40 分钟，明天再继续。':'今天已练满 30 分钟，建议在这里结束。'));
      else panel.append(node('p',fault||'等待时间确认后继续。','muted'));
      if(s&&s.used>=TARGET_SECONDS&&!s.extended)panel.append(button('再练最多 10 分钟',()=>pulse(c,true)));
      else if(fault)panel.append(button('重新连接',()=>{stop();begin();}));
    }
    if(!blocked&&screen==='practice') {
      if(s.credit>30)panel.append(node('p','已预留当前离线时段。断网后可在当前页继续，最多 10 分钟；提前退出请联网释放余额。','muted'));
      else panel.append(button('预留当前离线练习时段（最多 10 分钟）',()=>pulse(c,false,true)));
    }
    panel.append(button('暂停并回首页',leave));if(enabled())panel.append(button('切回经典界面',classic));
  }
  const TARGET_SECONDS=1800;
  async function perform(fn) {
    if(working||closed()||screen!=='course')return;
    const v=version,c=run;working=true;note='';render();
    try{const value=await fn(c);if(version===v&&screen==='course'&&run===c)value();}
    catch(e){if(version===v)note=e.message;}
    finally{if(version===v){working=false;render();}}
  }
  function loadLesson(){return perform(async c=>{const l=await api('lesson',{track:selection},c.id,c.headers);
    return ()=>{lesson=l;feedback=false;textShown=false;plays=0;};});}
  function markAid(t,kind) {
    return perform(async c=>{
      if(kind==='play'&&!await playText(t.passage,false))throw Error('暂时无法播放，可选择看原文。');
      const value=await api('aid',{task:t.id,kind,event:uuid()},c.id,c.headers);
      return ()=>{lesson=value;};
    });
  }
  function render() {
    if(screen!=='course')return;
    const host=app();host.replaceChildren();const card=node('div','','card');host.append(card);
    if(!lesson){card.append(node('h2','今日听读'),node('p',note||'正在准备课程…'));if(!working)card.append(button('取回今日课程',loadLesson));return;}
    card.append(node('p',lesson.focus+' · '+(lesson.track==='life'?'生活':'工作'),'muted'));
    const t=lesson.task,last=lesson.last;
    if(feedback&&last){
      card.append(node('h2',last.ok?'理解正确':'一起看这条线索'),node('p',last.explanation),node('p','正确行动 · '+last.expected));
      const details=document.createElement('details');details.append(node('summary','试着回应一句，再看参考说法（可选）'),node('p',last.reply));card.append(details);
      card.append(button('请 AI 再讲一句',()=>perform(async c=>{const r=await api('explanation',{},c.id,c.headers);return ()=>{modelNote=(r.ai?'AI 教练 · ':'课程题解 · ')+r.text;};})));
      if(modelNote)card.append(node('p',modelNote));
      card.append(button(t?'继续':'看本课小结',()=>{feedback=false;modelNote='';textShown=false;plays=0;render();},true));
    }else if(t) {
      card.append(node('h2',t.purpose+' · '+(lesson.step+1)+'/'+lesson.count),node('p',lesson.reason,'muted'));
      textShown=t.shown;plays=t.plays;
      if(t.kind==='listen')card.append(button(plays?'再听一遍':'播放消息',()=>markAid(t,'play')),button('看原文',()=>markAid(t,'transcript')));
      if(t.kind==='read'||textShown)card.append(node('blockquote',t.passage));
      if(t.hint)card.append(node('p',t.hint,'muted'));
      card.append(node('h3',t.question));
      t.options.forEach((o,i)=>{const b=button(o,()=>perform(async c=>{
        stopAudio();const l=await api('answer',{task:t.id,choice:i,mode:t.hint?'assisted':t.kind==='read'?'read':textShown?'assisted':'listen',replay:plays>1},c.id,c.headers);
        return ()=>{lesson=l;feedback=true;modelNote='';};
      }));b.className='opt';b.disabled=working||(t.kind==='listen'&&!textShown&&!plays);card.append(b);});
    }else{
      card.append(node('h2','今日教练课完成'),node('p','本课 '+lesson.step+' 道任务，独立理解 '+lesson.independent+' 道。'),
        node('p',last?.ok&&last.mode!=='assisted'?'下一课换一个理解重点。':'下一课将换材料再验证这个重点。'),button('返回首页',leave,true));
      if(run){stop();screen='summary';box().hidden=true;}
    }
    if(note){card.append(node('p',note,'warn'),button('取回最新进度',loadLesson));}
    if(working)card.querySelectorAll('button').forEach(b=>b.disabled=true);
  }
  return {page:switchPage};
})();
