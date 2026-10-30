import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from app.content_quality import judge_score,translation_issue,sentence_issue
for malformed in ('5','5 5 5 5','5 5 5 5 5','5 5 5 5 5 5 5','5 5 5 5 5 6','0 5 5 5 5 5','5.0 5 5 5 5 5','评分: 5 5 5 5 5 5','[5,5,5,5,5,5]',None):assert judge_score(malformed)==0,malformed
assert judge_score(' 5 4 5 5 4 5\n')==4
assert judge_score('5 5 5 3 5 5')==3
assert translation_issue('中文�')
assert translation_issue('') and translation_issue('English only') and translation_issue('中文 <script>')
assert translation_issue('她把苹果放在桌上。') is None
assert sentence_issue('She put the book on the table.','apple')=='missing-target'
print('PASS complete six-dimension review, strict ranges, missing Chinese and missing target rejected')
