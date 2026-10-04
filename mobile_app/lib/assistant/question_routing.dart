/// Normalize English topics for local rules while retaining older Chinese chats.
String normalizeAssistantQuestion(String text) {
  var result = text.trim().toLowerCase();
  for (final entry in _englishTopics.entries) {
    result = result.replaceAll(
      RegExp(entry.key, caseSensitive: false),
      entry.value,
    );
  }
  return result;
}

const _englishTopics = <String, String>{
  r'\b(measure.*dose|how much medication|how many pills)\b': '测出多少药剂量',
  r'\b(missed dose|missed medication|forgot (to take|my medication))\b': '漏服',
  r'\b(increase dose|reduce dose|change medication|stop medication|dosage|side effects?|diagnos\w*)\b':
      '诊断',
  r'\b(should i take|take an extra|make up a dose)\b': '补服',
  r'\b(sync (failed|fails|failure|error)|cannot sync|can.t sync)\b': '同步失败',
  r'\b(cannot connect|can.t connect|connection fail\w*|cannot find the device)\b':
      '连不上',
  r'\b(how many records|total records|records are saved|saved records|total count)\b':
      '多少条',
  r'\b(how many uses|use count|number of uses)\b': '次数',
  r'\b(up to date|latest|freshness)\b': '最新',
  r'\b(days without records|no records|blank days|missing records|gaps?)\b':
      '空白',
  r'\b(large[r]? text|font size|small text|text too small)\b': '大字',
  r'\b(clear chat|delete chat|clear conversation)\b': '清空对话',
  r'\b(search chat|search|find messages)\b': '搜索',
  r'\b(read aloud|text.to.speech|tts|voice|speech|pitch|speed)\b': '朗读',
  r'\b(add api|enable online|online mode|api key|model service|my model)\b':
      '添加 api',
  r'\b(what can i ask|what can you do|how to use|help|features)\b': '帮助',
  r'\b(source|where.*records.*come from|import)\b': '数据来源',
  r'\b(export|spreadsheet|share)\b': '导出',
  r'\b(attention|advice|suggestions?|recommendations?)\b': '注意',
  r'\b(invalid|unusual|abnormal|anomal\w*)\b': '异常',
  r'\b(today)\b': '今天',
  r'\b(last 7 days|last week|week|weekly)\b': '一周',
  r'\b(recent\w*|pattern\w*|trend\w*)\b': '最近',
  r'\b(bluetooth|ble|pairing)\b': '蓝牙',
  r'\b(sync\w*)\b': '同步',
  r'\b(clock|timestamp\w*|time|date|calibrat\w*)\b': '时间',
  r'\b(device)\b': '设备',
  r'\b(daily|every day)\b': '逐日',
  r'\b(local|offline)\b': '本地',
  r'\b(privacy|upload|what.*send)\b': '隐私',
  r'\b(dose|medication|ingestion)\b': '服药',
};
