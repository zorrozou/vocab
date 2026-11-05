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
    return {level:Math.max(0,Math.min(20000,Number(S.frontier)||0)),due:Math.min(100,dailyPlanSummary(S).duePlanned),words:weak,voice:S.settings.voice||"en-US-AriaNeural"};
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
    edition=v;focusKey='';lesson=null;feedback=false;modelNote='';replyDraft='';replyResult=null;revising=false;note='';
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
        pair('h2',d?.titleEn||'Today’s lesson',d?.title||'准备今天的听读课','home-title'),node('p',d?.reason||'先听懂一则消息，再到新情境独立做决定。'));
      if(d){hero.append(node('span',d.focus+' · '+(d.source||(d.prepared?'AI 材料已就绪':'教研材料可用')),'studio-chip'));}
      const primary=control(d?.complete?'View recap':d?.started?'Resume lesson':prepping?'Preparing lesson…':'Start lesson',d?.complete?'查看今日成果':d?.started?'继续今日课程':prepping?'正在为你备课…':'进入今日教练课',()=>startCourse(),'primary');primary.disabled=false;actions.append(primary);
      if(!d?.started&&!d?.prepared){const b=control('Use prepared material','直接使用教研课程',()=>startCourse());b.disabled=!d;actions.append(b);}
      const route=node('div','','studio-route');
      for(const [n,en,zh] of [['01','Understand','理解消息'],['02','Choose','核对行动'],['03','Try again','换境验证']]){const stop=node('span');stop.append(node('b',n),pair('small',en,zh));route.append(stop);}
      hero.append(route,actions);if(homeMessage)hero.append(node('p',homeMessage,'muted'));wrap.append(hero);
      const body=node('div','','studio-body'),grid=node('div','','studio-grid');
      body.append(node('h3','今天怎样分配时间'));const nums=d?.minutes||[8,20,2];
      ['听读任务','词汇复习','可选回应'].forEach((label,i)=>grid.append(metric(nums[i]+' 分',label)));
      const band=node('div','','studio-allocation');band.setAttribute('aria-hidden','true');
      nums.forEach(n=>{const segment=node('i');segment.style.flexGrow=String(n);band.append(segment);});
      body.append(band,grid,node('p','按约 30 分钟安排内容。30–40 分钟仅供参考，可随时继续或结束。','muted'));
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
  function closed(){return active()&&(!run||document.hidden);}
  function stop() {
    stopVoice();const old=run;if(old){checkpoint(old);void pulse(old);}run=null;version++;clearTimeout(timer);clearTimeout(expire);
    app().inert=false;

  }
  function classic() { cancelAutoStart();stopAudio();stop();localStorage.setItem(key(),'classic');home(); }
  function leave() { stopAudio();stop();home(); }
  function switchPage(next) {
    document.body.classList.toggle('studio-course',next==='course');
    if(screen!==next || (run && run.owner!==key())){cancelAutoStart();stop();screen=next;fault='';note='';working=false;}
    box().hidden=screen==='other';
    if(box().hidden){document.body.classList.remove('studio-home');return;}
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
  const timePrefix=owner=>'vocab.study.intervals.v3.'+owner+'.';
  function pendingTime(owner){
    const prefix=timePrefix(owner),rows=[];
    for(let i=0;i<localStorage.length;i++){
      const k=localStorage.key(i);if(k?.startsWith(prefix)){try{rows.push(JSON.parse(localStorage.getItem(k)));}catch(_){}}
    }
    return rows.sort((a,b)=>a.start-b.start);
  }
  function checkpoint(c){
    const now=performance.now(),elapsed=(now-c.tick)/1000;
    if(elapsed>0&&elapsed<=60){
      const row={id:uuid(),start:c.wall,end:c.wall+elapsed,activity:c.activity};
      try{localStorage.setItem(timePrefix(c.owner)+row.id,JSON.stringify(row));}catch(_){/* Storage failure cannot block a lesson. */}
    }
    c.tick=now;c.wall=Date.now()/1000;
  }
  async function begin() {
    if(run||!active()||document.hidden)return;
    const c={id:uuid(),owner:key(),snapshot:null,headers:null,tick:performance.now(),wall:Date.now()/1000,activity:screen==='course'?'class':'vocab',uploading:false};
    run=c;fault='';app().inert=false;paintBar();
    const tick=()=>{if(run!==c)return;checkpoint(c);void pulse(c);paintBar();timer=setTimeout(tick,15000);};
    timer=setTimeout(tick,15000);
    try{
      c.headers=await personalHeaders();if(run!==c||key()!==c.owner)return;
      // Content and time use independent requests. A slow clock never delays lesson entry.
      if(screen==='course'&&!lesson&&!working)void loadLesson();
      void pulse(c);
    }catch(e){if(run===c){note=e.message;render();}}
  }
  async function pulse(c) {
    if(c.uploading||!c.headers)return;
    c.uploading=true;
    try {
      const segments=pendingTime(c.owner).slice(0,100);
      const snapshot=await api('clock',{action:'record',segments},c.id,c.headers);
      for(const id of snapshot.acknowledged||[])localStorage.removeItem(timePrefix(c.owner)+id);
      if(run===c&&key()===c.owner){c.snapshot=snapshot;paintBar();}
    }catch(_){/* Persisted intervals retry on the next tick or visit. */}
    finally{c.uploading=false;}
  }
  function paintBar() {
    const host=box();host.replaceChildren();
    document.body.classList.toggle("studio-home",screen==="home"&&enabled()&&availability);
    if(screen==='other'){host.hidden=true;return;}
    host.hidden=false;
    const panel=node('div','', 'card');host.append(panel);
    if(screen==='home') {
      if(!availability){host.hidden=true;return;}
      if(!enabled()){panel.append(node('small','经典词航 · 与教练课合并记录用时 '),button('开启听读教练',()=>{localStorage.setItem(key(),'on');refreshHome();paintBar();}));return;}
      host.replaceChildren();studioHome(host);
      return;
    }
    const c=run,s=c?.snapshot;app().inert=closed();
    const local=c?pendingTime(c.owner).filter(x=>new Date(x.start*1000).toLocaleDateString('en-CA')===today()).reduce((n,x)=>n+x.end-x.start,0):0;
    const spent=(s?.day===today()?s.used:0)+local;
    panel.append(node('strong','今日已练 '+Math.floor(spent/60)+' 分钟 · 用时仅作参考'));
    if(screen==='course'){panel.classList.add('lesson-toolbar');panel.append(control('Pause lesson','暂停并回首页',leave,'quiet'));}
    else {panel.append(button('暂停并回首页',leave));if(enabled())panel.append(button('切回经典界面',classic));}
  }
  async function perform(fn) {
    if(working||closed()||screen!=='course')return;
    const v=version,c=run;working=true;note='';render();
    try{if(!c.headers)c.headers=await personalHeaders();const value=await fn(c);if(version===v&&screen==='course'&&run===c)value();}
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
  function pair(tag,en,zh,cls=''){
    const el=node(tag,'','language-pair '+cls);
    if(en){const english=node('span',en,'line-en');english.lang='en';el.append(english);}
    if(zh){const chinese=node('span',zh,en?'line-zh':'line-en');chinese.lang='zh-CN';el.append(chinese);}
    return el;
  }
  function control(en,zh,fn,cls='secondary'){
    const b=action('',fn,cls);b.append(pair('span',en,zh));return b;
  }
  const stages={'接收消息':'Understand the message','核对线索':'Check the clue','做出行动':'Choose an action','独立迁移':'Try a new situation',
    '先独立理解':'Try it on your own','带着线索再试':'Check the clue','换个情境验证':'Try a new situation'};
  let replyOpen=false,focusKey='';
  function render() {
    if(screen!=='course')return;
    const host=app();host.replaceChildren();const card=node('article','','studio studio-lesson');host.append(card);
    if(!lesson){card.append(pair('h2','Getting your lesson ready',note||'正在准备课程…'));if(!working)card.append(control('Try again','取回今日课程',loadLesson));return;}
    const t=lesson.task,last=lesson.last,reviewing=feedback&&last;
    const stage=reviewing?'Feedback':t?.kind==='listen'?'Listening':'Reading';
    const title=reviewing?(last.ok?'You got it':'Look at the clue'):t?(t.titleEn||stages[t.purpose]||'Your next task'):'Lesson complete';
    const zh=reviewing?(last.ok?'理解正确':'一起看这条线索'):t?(t.title||t.purpose):'今日教练课完成';
    const head=node('header','','lesson-header');card.append(head);
    const eyebrow=node('div','','lesson-meta');eyebrow.append(node('span',t||reviewing?stage.toUpperCase():'RECAP'),node('span',(lesson.source||'教研课程')+' · '+(goals[lesson.track]||'听读课堂')));head.append(eyebrow);
    const heading=pair('h2',title,zh,'lesson-title');heading.tabIndex=-1;head.append(heading);
    const line=node('div','','studio-steps');line.setAttribute('role','progressbar');line.setAttribute('aria-label','已完成任务');
    line.setAttribute('aria-valuemin','0');line.setAttribute('aria-valuemax',lesson.count);line.setAttribute('aria-valuenow',lesson.step);
    for(let i=0;i<lesson.count;i++)line.append(node('i','',i<lesson.step?'on':''));head.append(line);
    const body=node('div','','lesson-body');card.append(body);
    const focusId=lesson.day+'/'+lesson.step+'/'+(reviewing?'feedback':t?.id||'done');
    if(focusKey!==focusId){focusKey=focusId;replyOpen=false;heading.focus({preventScroll:true});card.scrollIntoView({block:'nearest'});}
    if(reviewing){
      const evidence=node('section','',last.ok?'answer-evidence correct':'answer-evidence revise');
      evidence.append(node('div','THE ANSWER  /  正确行动','studio-kicker'),pair('h3',last.expectedEn,last.expected),pair('p',last.explanationEn,last.explanation));
      body.append(evidence);
      const next=control(t?'Continue':'See my recap',t?'继续':'看本课小结',()=>{stopVoice();feedback=false;modelNote='';replyDraft='';replyResult=null;revising=false;textShown=false;plays=0;render();},'primary');
      body.append(next);
      const supplemental=node('div','','lesson-support');body.append(supplemental);
      const example=node('details');example.append(pair('summary','See a sample reply','查看参考说法'),node('p',last.reply));supplemental.append(example);
      supplemental.append(control('Explain the clue','请 AI 再讲一句',()=>perform(async c=>{const r=await api('explanation',{},c.id,c.headers);return ()=>{modelNote=r;};}),'quiet'));
      if(modelNote)supplemental.append(pair('p',modelNote.textEn,(modelNote.ai?'AI 教练 · ':'课程题解 · ')+modelNote.text,'clue-note'));
      if(edition===2){
        const compose=node('details');compose.open=replyOpen;compose.ontoggle=()=>{if(compose.isConnected)replyOpen=compose.open;};
        compose.append(pair('summary','Try a short reply','可选 · 写一句英语回应'));supplemental.append(compose);
        const result=replyResult||last.response;
        if(result&&!revising){
          const verdict={'表达清楚':'Your meaning is clear','可以更明确':'Try being more specific','暂无法判断':'Check the example'};
          compose.append(pair('h3',verdict[result.verdict],result.verdict),pair('p',result.tipEn,result.tip),pair('p',result.example,'参考说法'));
          if((result.attempt||0)<2)compose.append(control('Try again',result.attempt?'改一句再试':'重新尝试反馈',()=>{replyDraft='';revising=true;render();}));
        }else{
          const area=node('textarea');area.maxLength=180;area.lang='en';area.placeholder='Write one sentence…';area.setAttribute('aria-label','我的英文回应');area.value=replyDraft;area.oninput=()=>{replyDraft=area.value;};compose.append(area);
          if(window.SpeechRecognition||window.webkitSpeechRecognition)compose.append(control(recognizer?'Stop dictation':'Dictate a reply',recognizer?'结束听写':'口述一句，先核对文字',()=>dictate(last.id)),node('p','浏览器可能通过其语音服务转写。确认文字后再发送。','muted'));
          compose.append(node('p','点击后才发送文字。只保存反馈，不计词汇掌握。','muted'),control('Check my reply','看看我的回应',()=>{
            stopVoice();if(!replyDraft.trim()){area.focus();return;}
            perform(async c=>{const r=await api('reply',{task:last.id,text:replyDraft.trim(),attempt:result?.attempt===1?2:1},c.id,c.headers);return ()=>{replyResult=r;revising=false;};});
          }));
        }
        supplemental.append(control('Undo my choice','撤销这次选择',()=>perform(async c=>{const l=await api('undo',{task:last.id},c.id,c.headers);return ()=>{lesson=l;feedback=false;replyDraft='';replyResult=null;};}),'quiet'));
      }
    }else if(t){
      textShown=t.shown;plays=t.plays;
      if(t.kind==='listen'&&!textShown&&!plays)body.append(pair('p','Listen first, then choose.','先听消息，再选择行动。','task-stage'));
      else if(t.title)body.append(pair('p',stages[t.purpose]||'Choose the best answer',t.purpose,'task-stage'));
      if(t.kind==='listen'){
        const audio=node('div','','audio-actions');
        audio.append(control(plays?'Listen again':'Play audio',plays?'再听一遍':'播放消息',()=>markAid(t,'play'),'primary'),control('Transcript','看原文',()=>markAid(t,'transcript')));
        body.append(audio);
      }
      if(t.kind==='read'||textShown){const passage=node('blockquote',t.passage);passage.lang='en';body.append(passage);}
      if(t.hint)body.append(pair('p',t.hint.includes('重选')?'Try again with the feedback in mind.':'Check the message again.',t.hint,'clue-note'));
      body.append(pair('h3',t.questionEn,t.question,'task-question'));
      const choices=node('div','','answer-choices');body.append(choices);
      t.options.forEach((o,i)=>{
        const b=control(t.optionsEn?.[i],o,()=>perform(async c=>{
          stopAudio();const l=await api('answer',{task:t.id,choice:i,mode:t.hint?'assisted':t.kind==='read'?'read':textShown?'assisted':'listen',replay:plays>1},c.id,c.headers);
          return ()=>{lesson=l;feedback=true;modelNote='';};
        }),'opt');
        const letter=node('span',String.fromCharCode(65+i),'choice-letter');letter.setAttribute('aria-hidden','true');b.prepend(letter);
        b.disabled=working||(t.kind==='listen'&&!textShown&&!plays);choices.append(b);
      });
      const why=node('details');why.append(pair('summary','Why this task?','为什么练这一题'),node('p',lesson.reason));
      if(lesson.words?.length)why.append(node('p','课中复现 · '+lesson.words.join(' / ')));body.append(why);
    }else{
      body.append(pair('h3',lesson.independent+' of '+lesson.step+' tasks completed independently','本课 '+lesson.step+' 道任务，独立理解 '+lesson.independent+' 道。'),node('p',lesson.debrief||'本轮结果已记录。'),
        control('Back to today','返回首页',leave,'primary'),control('Practice vocabulary','接着练今天的词汇',()=>{leave();(document.querySelector('#bStart')||document.querySelector('#bPlace'))?.click();}));
      if(run){stop();screen='summary';box().hidden=true;}
    }
    if(note){body.append(node('p',note,'warn'),control('Reload lesson','取回最新进度',loadLesson));}
    if(working)card.querySelectorAll('button').forEach(b=>b.disabled=true);
  }
  async function finish(){
    const who=key(),context={...learnerContext(),position:S.pointer,new_words:(S.pendingNew||[]).slice(0,10).map(x=>x.word),
      review_words:Object.entries(S.cards).filter(([,c])=>!isMastered(c)).sort((a,b)=>String(scheduledDue(a[1],S.fsrsSchedulers)||'9999').localeCompare(String(scheduledDue(b[1],S.fsrsSchedulers)||'9999'))).slice(0,15).map(([w])=>w)};
    try{const headers=await personalHeaders();if(who===key())await api('finish',context,uuid(),headers);}catch(_){}
  }
  return {page:switchPage,finish};
})();
