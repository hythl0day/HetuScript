import 'package:hetu_script/hetu.dart';

void main() {
  hetu.init(workingDir: 'ht_example');
  hetu.evalf('script\\list.ht', invokeFunc: 'main');
}
