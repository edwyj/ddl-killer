// Date evidence comes only from user messages, never an assistant's guesses.
const DAY=86400000;
export function planningRequestDates(request,history=[],clock) {
  const references=[];
  for(const turn of [...history,{input:request}]) {
    const input=turn.input;
    if(typeof input!=='string')continue;
    const anchor=turn.date??clock.date;
    const today=Date.parse(anchor+'T00:00:00Z');
    const monday=today-((new Date(today).getUTCDay()+6)%7)*DAY;
    const pattern=/(下下|下|这|本)(?:周|星期)([一二三四五六日天])|今天|明天|后天/g;
    for(const match of input.matchAll(pattern)) {
      const [text,week,weekday]=match;
      const timestamp=week?monday+((week==='下下'?2:week==='下'?1:0)*7+(weekday==='天'?6:'一二三四五六日'.indexOf(weekday)))*DAY:
        today+(text==='后天'?2:text==='明天'?1:0)*DAY;
      const date=new Date(timestamp).toISOString().slice(0,10);
      const existing=references.findIndex(r=>r.text===text);
      if(existing>=0)references.splice(existing,1);
      references.push({text,date});
    }
  }
  return references;
}

export function extendPlanningRange(startDate,endDate,references) {
  const max=Date.parse(startDate+'T00:00:00Z')+13*DAY;
  for(const r of references)if(r.date>endDate&&Date.parse(r.date+'T00:00:00Z')<=max)endDate=r.date;
  return {startDate,endDate};
}
