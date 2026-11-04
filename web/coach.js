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
      headers:{...headers,'Content-Type':'application/json'},signal:AbortSignal.timeout(path==='prepare'?115000:['explanation','reply'].includes(path)?50000:9000),
      body:JSON.stringify({edition,activity:screen==="course"?"class":"vocab",...data,client:id,offset:-new Date().getTimezoneOffset()})});
    if(!res.ok){const e=await res.json().catch(()=>({}));throw Error(typeof e.detail==='string'?e.detail:'无法连接教练');}
    return res.json();
  }
  const goals={life:'日常听说',work:'职场沟通',read:'阅读理解'};
  let tab='today',report=null,reportOwner='',homeRequest=0,prepRequest=0,prepping=false,homeMessage='',edition=2;
  let replyDraft='',replyResult=null,revising=false,recognizer=null,voiceTimer=null;
  function stopVoice(){
    if(recognizer){recognizer.onresult=null;recognizer.onerror=null;recognizer.onend=null;recognizer.abort();recognizer=null;}
    clearTimeout(voiceTimer);
  }
  function dictate(id){
    if(recognizer){recognizer.stop();return;}
    const Speech=window.SpeechRecognition||window.webkitSpeechRecognition;
    if(!Speech||closed())return;
    const rec=new Speech(),v=version;recognizer=rec;rec.lang='en-US';rec.interimResults=false;
    rec.onresult=e=>{if(v===version&&feedback&&lesson?.last?.id===id&&!closed())replyDraft=e.results[0][0].transcript.slice(0,180);};
    rec.onerror=()=>{if(v===version)note='语音未识别，可以直接打字。';};
    rec.onend=()=>{if(recognizer===rec){recognizer=null;clearTimeout(voiceTimer);if(v===version)render();}};
    try{rec.start();voiceTimer=setTimeout(()=>rec.stop(),15000);render();}catch(_){stopVoice();note='语音不可用，可以直接打字。';render();}
  }
  function learnerContext(){
    const weak=Object.entries(recentDifficult(S)).filter(([w])=>!isMastered(S.cards[w]||{}))
      .sort((a,b)=>(b[1].again*2+b[1].hard)-(a[1].again*2+a[1].hard)).slice(0,3).map(([word])=>word);
    return {level:Math.max(0,Math.min(20000,Number(S.frontier)||0)),due:Math.min(100,dailyPlanSummary(S).duePlanned),words:weak};
  }
  async function refreshHome(goal=null,study=null){
    const who=key(),seq=++homeRequest;
    if(reportOwner!==who){report=null;homeMessage='';tab='today';reportOwner=who;prepping=false;}
    try{
      const headers=await personalHeaders();
      const value=await api('dashboard',{...learnerContext(),...(goal?{goal}:{}),...(study===null?{}:{study})},uuid(),headers);
      if(seq!==homeRequest||who!==key()||screen!=='home')return;
      report=value;selection=value.goal;paintBar();
    }catch(e){if(seq===homeRequest&&who===key()&&screen==='home'){homeMessage=e.message;paintBar();}}
  }
  function cancelAutoStart(){
    prepRequest++;prepping=false;homeMessage='';
  }
  async function prepare(autoStart=false){
    if(prepping)return;
    const who=key(),goal=selection,request=++prepRequest;
    const stillHere=()=>request===prepRequest&&who===key()&&screen==='home'&&tab==='today'&&enabled()&&selection===goal;
    prepping=true;homeMessage='正在编写三个情境并逐题审校，你可以先开始教研课程。';paintBar();
    try{
      const r=await api('prepare',{...learnerContext(),track:goal},uuid(),await personalHeaders());
      if(stillHere()){homeMessage=r.message;if(autoStart)startCourse();}
    }catch(e){if(stillHere()){homeMessage='备课暂未取回，可以使用教研课程。';if(autoStart)startCourse();}}
    finally{if(request===prepRequest&&who===key()){prepping=false;if(screen==='home')refreshHome();}}
  }
  function startCourse(v=2){
    edition=v;lesson=null;feedback=false;modelNote='';replyDraft='';replyResult=null;revising=false;note='';
    app().replaceChildren();switchPage('course');
  }
  function metric(value,label){
    const n=node('div','','studio-metric');n.append(node('strong',String(value)),node('span',label));return n;
  }
  function action(label,fn,cls='secondary'){
    const b=button(label,fn);b.className=cls;return b;
  }
  function studioHome(host){
    const d=reportOwner===key()?report:null;
    host.className='studio';
    const wrap=node('div','','studio-shell'),nav=node('nav','','studio-nav');wrap.append(nav);host.append(wrap);
    for(const [id,label] of [['today','今日课堂'],['record','学习档案'],['goals','我的目标']]){
      const b=action(label,()=>{if(tab!==id)cancelAutoStart();tab=id;paintBar();if(id==='today')refreshHome();},'quiet');b.setAttribute('aria-pressed',String(tab===id));nav.append(b);
    }
    if(tab==='today'){
      const hero=node('div','','studio-hero'),actions=node('div','','studio-actions');
      hero.append(node('div','听读工作室  /  '+(goals[d?.currentGoal||'life']),'studio-kicker'),
        node('h2',d?.title||'准备今天的听读课'),node('p',d?.reason||'先听懂一则消息，再到新情境独立做决定。'));
      if(d){hero.append(node('span',d.focus+' · '+(d.source||(d.prepared?'AI 材料已就绪':'教研材料可用')),'studio-chip'));}
      const primary=action(d?.complete?'查看今日成果':d?.started?'继续今日课程':prepping?'正在为你备课…':'进入今日教练课',()=>{if(d?.started||d?.prepared||d?.study?.on)startCourse();else prepare(true);},'primary');primary.disabled=prepping||!d;actions.append(primary);
      if(!d?.started&&!d?.prepared){const b=action('直接使用教研课程',()=>startCourse());b.disabled=!d;actions.append(b);}
      const route=node('div','','studio-route');
      for(const [n,label] of [['01','理解消息'],['02','核对行动'],['03','换境验证']]){const stop=node('span');stop.append(node('b',n),node('small',label));route.append(stop);}
      hero.append(route,actions);if(homeMessage)hero.append(node('p',homeMessage,'muted'));wrap.append(hero);
      const body=node('div','','studio-body'),grid=node('div','','studio-grid');
      body.append(node('h3','今天怎样分配时间'));const nums=d?.minutes||[8,20,2];
      ['听读任务','词汇复习','可选回应'].forEach((label,i)=>grid.append(metric(nums[i]+' 分',label)));
      const band=node('div','','studio-allocation');band.setAttribute('aria-hidden','true');
      nums.forEach(n=>{const segment=node('i');segment.style.flexGrow=String(n);band.append(segment);});
      body.append(band,grid,node('p','按当前剩余时间建议分配。30 分钟收课，主动延长最多至 40 分钟。','muted'));
      if(d?.weak.length)body.append(node('p','近期练词线索 · '+d.weak.join(' / '),'muted'));
      if(d?.legacy)body.append(action('接着完成上一版的课',()=>startCourse(1),'quiet'));
      wrap.append(body);
    }else if(tab==='record'){
      const body=node('div','','studio-body');body.append(node('div','近 7 天  /  真实作答','studio-kicker'),node('h2','我的学习档案'));
      if(d){
        const grid=node('div','','studio-grid');for(const [k,title] of [['listen','首听答对'],['replay','重听答对'],['read','独立读懂'],['assisted','借助提示答对'],['miss','需要再练']])grid.append(metric(d.signals[k],title));
        body.append(grid,node('h3','能力与记录'));
        d.skills.forEach(s=>body.append(node('div',s.label+'　'+(s.attempts?s.independent+' 次独立 / '+s.attempts+' 次作答':'待观察'),'studio-line')));
        body.append(node('h3','课堂手记')); if(!d.diary.length)body.append(node('p','完成第一道题后，这里会显示哪一天、练了什么、依据是什么。','muted'));
        d.diary.forEach(x=>body.append(node('div',x.day+' · '+x.outcome+'｜'+x.focus+' · '+x.fact,'studio-line')));
        body.append(node('h3','延迟验证'));body.append(node('p',d.reviews.length?d.reviews.map(x=>x.day+' · '+x.interval+' 天复查 · '+(x.ok?'独立完成':'继续观察')).join('　'):'尚无延迟验证。教练会在第 7 天和第 30 天前后的可用课次安排复查。','muted'));
        if(d.study?.on)body.append(node('h3','学习方式对照'),node('p',d.study.pairs?'可比复测 '+d.study.pairs+' 对 · 分支课独立完成 '+d.study.adaptive+' 次，固定课 '+d.study.fixed+' 次。只展示观察值。':'尚无同条件的成对复测，暂不判断效果。','muted'));
      }wrap.append(body);
    }else{
      const body=node('div','','studio-body');body.append(node('div','学习方向','studio-kicker'),node('h2','你希望英语帮你做什么？'));
      for(const [id,label] of Object.entries(goals)){
        const b=action((d?.goal===id?'✓ ':'')+label,()=>{homeMessage='';refreshHome(id);},d?.goal===id?'primary':'secondary');body.append(b);
      }
      body.append(node('p','目标随账号保存；已经开始的一课保留原教材。','muted'),node('h3','可选的学习方式对照'),
        node('p','开启后，同一目标和教学重点的不同课次成对采用固定练习或错项分支。两组共用教研材料；只比较相同延迟、模态和相近训练用时的陌生题。可随时退出。','muted'));
      body.append(action(d?.study?.on?'退出学习方式对照':'参加学习方式对照',()=>refreshHome(null,!d?.study?.on),'quiet'));wrap.append(body);
    }
    host.append(action('切回经典界面',classic,'quiet'));
  }
  function closed(){return active()&&(!run||performance.now()>=run.until);}
  function stop() {
    stopVoice();const old=run;run=null;version++;clearTimeout(timer);clearTimeout(expire);
    app().inert=false;
    if(old?.headers)api('clock',{action:'stop'},old.id,old.headers).catch(()=>{});
  }
  function classic() { cancelAutoStart();stopAudio();stop();localStorage.setItem(key(),'classic');home(); }
  function leave() { stopAudio();stop();home(); }
  function switchPage(next) {
    if(screen!==next || (run && run.owner!==key())){cancelAutoStart();stop();screen=next;fault='';note='';working=false;}
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
    if(next==='home'&&enabled())refreshHome();
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
        expire=setTimeout(()=>{if(run===c&&closed()){stopVoice();stopAudio();app().inert=true;paintBar();}},c.until-performance.now());
        timer=setTimeout(()=>pulse(c),Math.max(100,Math.min(10000,c.until-performance.now())));
        if(screen==='course'&&!lesson&&!working)loadLesson();
      }else if(snapshot.used<snapshot.limit)timer=setTimeout(()=>pulse(c),snapshot.busy?3000:500);
      paintBar();
    }catch(e){if(run===c){fault=e.message;paintBar();}}
  }
  function paintBar() {
    const host=box();host.replaceChildren();
    document.body.classList.toggle("studio-home",screen==="home"&&enabled()&&availability);
    if(screen==='other'){host.hidden=true;return;}
    host.hidden=false;
    const panel=node('div','', 'card');host.append(panel);
    if(screen==='home') {
      if(!availability){host.hidden=true;return;}
      if(!enabled()){panel.append(node('small','经典词航 · 与教练课共用每日时间 '),button('开启听读教练',()=>{localStorage.setItem(key(),'on');refreshHome();paintBar();}));return;}
      host.replaceChildren();studioHome(host);
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
  function loadLesson(){return perform(async c=>{const l=await api('lesson',{track:selection,...learnerContext()},c.id,c.headers);
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
    const host=app();host.replaceChildren();const card=node('div','','studio studio-lesson');host.append(card);
    if(!lesson){card.append(node('h2','今日听读'),node('p',note||'正在准备课程…'));if(!working)card.append(button('取回今日课程',loadLesson));return;}
    card.append(node('div',(lesson.source||'教研课程')+' / '+(goals[lesson.track]||'听读课堂'),'studio-kicker'),
      node('h2',lesson.task?.title||lesson.title||lesson.focus));
    const line=node('div','','studio-steps'); for(let i=0;i<lesson.count;i++)line.append(node('i','',i<lesson.step?'on':''));
    card.append(line,node('p',lesson.focus+' · 已完成 '+lesson.step+' / '+lesson.count,'muted'));
    if(lesson.words?.length)card.append(node('p','课中复现 · '+lesson.words.join(' / '),'studio-chip'));
    const t=lesson.task,last=lesson.last;
    if(feedback&&last){
      card.append(node('h2',last.ok?'理解正确':'一起看这条线索'),node('p',last.explanation),node('p','正确行动 · '+last.expected));
      const details=document.createElement('details');details.append(node('summary','试着回应一句，再看参考说法（可选）'),node('p',last.reply));card.append(details);
      card.append(button('请 AI 再讲一句',()=>perform(async c=>{const r=await api('explanation',{},c.id,c.headers);return ()=>{modelNote=(r.ai?'AI 教练 · ':'课程题解 · ')+r.text;};})));
      if(modelNote)card.append(node('p',modelNote));
      if(edition===2){
        const area=node('textarea');area.maxLength=180;area.placeholder='用一句英语回应（可跳过）';area.setAttribute('aria-label','我的英文回应');area.value=replyDraft;area.oninput=()=>{replyDraft=area.value;};
        const result=replyResult||last.response;
        if(result&&!revising){
          card.append(node('h3',result.verdict),node('p',result.tip),node('p','参考 · '+result.example,'muted'));
          if((result.attempt||0)<2)card.append(action(result.attempt?'改一句再试':'重新尝试反馈',()=>{replyDraft='';revising=true;render();},'quiet'));
        }
        else {card.append(area);
          if(window.SpeechRecognition||window.webkitSpeechRecognition)card.append(action(recognizer?'结束听写':'口述一句，先核对文字',()=>dictate(last.id),'quiet'),node('p','浏览器可能通过其语音服务转写。确认文字后再发送。','muted'));
          card.append(node('p','点下按钮才发送这句话获取建议。只保存反馈，不计词汇掌握。','muted'),action('看看我的回应',()=>{
          stopVoice();if(!replyDraft.trim()){area.focus();return;}
          perform(async c=>{const r=await api('reply',{task:last.id,text:replyDraft.trim(),attempt:result?.attempt===1?2:1},c.id,c.headers);return ()=>{replyResult=r;revising=false;};});
        }));}
      }
      if(edition===2)card.append(action('撤销这次选择',()=>perform(async c=>{const l=await api('undo',{task:last.id},c.id,c.headers);return ()=>{lesson=l;feedback=false;replyDraft='';replyResult=null;};}),'quiet'));
      card.append(button(t?'继续':'看本课小结',()=>{stopVoice();feedback=false;modelNote='';replyDraft='';replyResult=null;revising=false;textShown=false;plays=0;render();},true));
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
      card.append(node('div','课堂回顾','studio-kicker'),node('h2','今日教练课完成'),node('p','本课 '+lesson.step+' 道任务，独立理解 '+lesson.independent+' 道。'),
        node('p',lesson.debrief||(last?.ok&&last.mode!=='assisted'?'下一课换一个理解重点。':'下一课将换材料再验证这个重点。')),button('返回首页',leave,true));
      card.append(action('接着练今天的词汇',()=>{leave();(document.querySelector('#bStart')||document.querySelector('#bPlace'))?.click();},'secondary'));
      if(run){stop();screen='summary';box().hidden=true;}
    }
    if(note){card.append(node('p',note,'warn'),button('取回最新进度',loadLesson));}
    if(working)card.querySelectorAll('button').forEach(b=>b.disabled=true);
  }
  return {page:switchPage};
})();
