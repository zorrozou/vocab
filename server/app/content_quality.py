"""Shared deterministic content gates; existing positions/IDs must not be renumbered."""
import re
FRAGMENTS = {"n't", "nt", "'s", "'re", "'ve", "'ll", "'d", "'m", "s", "t", "re", "ve", "ll", "d", "m"}
def valid_word(word):
    return isinstance(word,str) and word not in FRAGMENTS and bool(re.fullmatch(r"[a-z]+(?:[-'][a-z]+)*",word)) and (len(word)>1 or word in ('a','i'))

def sentence_issue(text, target, lemma=lambda x:x):
    if not isinstance(text,str) or not text.strip(): return 'empty'
    if any(t in text for t in ('<','>','{','}','�','___','http://','https://')): return 'placeholder-or-markup'
    tokens=re.findall(r"[A-Za-z]+(?:'[A-Za-z]+)?",text.lower())
    if len(tokens)<3: return 'too-short'
    # Normalize corpus contractions so function words aren't rejected artificially.
    expanded=[]
    for t in tokens:
        expanded.append(t)
        if t.endswith("n't"): expanded.extend([t[:-3], 'not'])
        if "'" in t: expanded.extend(t.split("'"))
    w=target.lower()
    forms={w,w+'s',w+'es',w+'ed',w+'d',w+'ing'}
    forms.update({'fling':{'flung'}}.get(w,set()))
    if w.endswith('e'): forms.add(w[:-1]+'ing')
    if w.endswith('y'): forms.update({w[:-1]+'ies',w[:-1]+'ied'})
    if len(w)>2: forms.update({w+w[-1]+'ed',w+w[-1]+'ing'})
    if not forms.intersection(expanded) and not any(lemma(t)==w for t in expanded): return 'missing-target' 
    if len(text)>500: return 'too-long'
    return None


def judge_score(output, dimensions=6):
    """An incomplete, out-of-range, or prose response is not a passing review."""
    if not isinstance(output,str) or not re.fullmatch(r'\s*[1-5](?:\s+[1-5]){'+str(dimensions-1)+r'}\s*',output): return 0
    return min(map(int,output.split()))


def translation_issue(text):
    if not isinstance(text,str) or not text.strip(): return 'missing-translation'
    if not re.search(r'[\u3400-\u9fff]',text): return 'missing-chinese-translation'
    if any(t in text for t in ('<','>','{','}','�','___','http://','https://')): return 'translation-markup'
    if len(text)>500: return 'translation-too-long'
    return None
