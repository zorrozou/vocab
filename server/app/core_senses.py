"""Reviewed common meanings that must precede archaic/technical ECDICT entries.
Existing word/sense IDs remain stable. Preserve other senses for dictionary lookup.
"""
OVERRIDES = {
 'like':('vt','喜欢；喜爱'), 'natural':('a','自然的；天然的'), 'despite':('prep','尽管；即使'),
 'southern':('a','南方的；南部的'), 'eastern':('a','东方的；东部的'), 'northern':('a','北方的；北部的'),
 'separate':('a','分开的；单独的'), 'leading':('a','主要的；领先的'), 'substantial':('a','大量的；重大的；结实的'),
 'teen':('n','青少年'), 'statue':('n','雕像'), 'shallow':('a','浅的；肤浅的'), 'stale':('a','不新鲜的；陈旧的'),
 'recipient':('n','接受者；收件人'), 'shatter':('v','打碎；粉碎'), 'subscribe':('v','订阅；订购'),
 'installment':('n','分期付款的一期；连载的一部分'), 'troubling':('a','令人担忧的'),
 'outgoing':('a','外向的；即将离任的'), 'paramount':('a','至关重要的；首要的'),
 'intestine':('n','肠'), 'literate':('a','有读写能力的'), 'retriever':('n','寻回猎犬'),
 'cola':('n','可乐'), 'conservatory':('n','温室；音乐学院'), 'flout':('vt','公然藐视；无视'),
 'raising':('n','提高；筹集；养育'), 'browser':('n','浏览器；浏览者'), 'abs':('n','腹肌'),
 'stat':('n','统计数据（statistic 的简称）'), 'mow':('v','割草；刈'), 'duo':('n','两人组合；二重奏'),
 'orgasm':('n','性高潮'), 'funky':('a','有强烈节奏的；时髦而独特的'), 'dick':('n','阴茎（粗俗用语）；讨厌的家伙（粗俗用语）'),
 'argentine':('a','阿根廷的'), 'topping':('n','食物的配料；浇头'), 'thirds':('n','三分之一（third 的复数）'),
 'mike':('n','麦克风（microphone 的非正式说法）'),
 'oriental':('a', '东方的（多用于艺术和物品；不宜用来称呼人）'),
 'crow':('n', '乌鸦'),
 'fling':('v', '猛扔；抛；甩'),
 'crank':('n', '曲柄；古怪的人'),
 'lateral':('a', '侧面的；横向的'),
 'clog':('v', '堵塞；阻塞'),
 'scuttle':('v', '小步快跑；匆忙逃走；故意使失败'),
 'auspice':('n', 'auspices 的单数；赞助，支持（通常用 under the auspices of）'),
 'ye':('pron', '你们（古语或仿古用法）'),
 'sucker':('n', '容易上当的人；吸盘；棒棒糖（美式口语）'),
 'repercussion':('n', '不良后果；间接影响'),
 'tacit':('a', '默示的；心照不宣的'),
 'clench':('v', '握紧；咬紧'),
 'residency':('n', '居住；居留资格；住院医师培训期'),
 'arousal':('n', '唤醒；兴奋'),
 'the':('art', '定冠词：用于指已知或特定的人或物'),
}

def apply_overrides(conn):
    changed=0
    for word,(pos,text) in OVERRIDES.items():
        row=conn.execute("SELECT s.id,s.pos,s.text FROM sense s JOIN lexicon_entry e ON e.id=s.wordId WHERE e.word=? AND s.role='core'",(word,)).fetchone()
        if row and (row[1],row[2])!=(pos,text):
            wid=conn.execute('SELECT wordId FROM sense WHERE id=?',(row[0],)).fetchone()[0]
            if not conn.execute('SELECT 1 FROM sense WHERE wordId=? AND pos=? AND text=? AND role!=?',(wid,row[1],row[2],'core')).fetchone():
                order=conn.execute('SELECT MAX(senseOrder) FROM sense WHERE wordId=?',(wid,)).fetchone()[0]+1
                conn.execute("INSERT INTO sense(wordId,senseOrder,pos,text,role) VALUES(?,?,?,?,'detail')",(wid,order,row[1],row[2]))
            conn.execute('UPDATE sense SET pos=?,text=? WHERE id=?',(pos,text,row[0]));changed+=1
    return changed
