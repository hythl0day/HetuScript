import 'package:test/test.dart';
import 'package:hetu_script/hetu_script.dart';

void main() async {
  final hetu = Hetu();
  await hetu.init();

  group('edge cases -', () {
    test('import', () async {
      final result =
          await hetu.import('script/import_test.ht', invokeFunc: 'importTest');
      expect(
        result,
        87.5,
      );
    });
    test('automatic semicolon insertion', () async {
      final result = await hetu.eval(r'''
        fun asi {
          var j = 3
          var i =
            ('all' 
            + 'oha')
          ++j
          if (i is num)
        return
            return j
        }
  ''', invokeFunc: 'asi');
      expect(
        result,
        4,
      );
    });
    test('late initialization', () async {
      final result = await hetu.eval(r'''
      fun getIndex {
        return 2
      }
      fun lateInit {
        var tables = { 'weapon': [1,2,3] }
        var rows = tables['weapon'];
        var i = getIndex()
        return rows[i]
      }
  ''', invokeFunc: 'lateInit');
      expect(
        result,
        3,
      );
    });
    test('late initialization 2', () async {
      final result = await hetu.eval(r'''
      fun lateInit2 {
        var list = [1,2,3,4]
        var item = list[3]
        list.removeLast()
        return item
      }
  ''', invokeFunc: 'lateInit2');
      expect(
        result,
        4,
      );
    });
    test('var in lambda', () async {
      final result = await hetu.eval(r'''
        class Left {
          var age = 10
          fun m() {
            var b = Right(fun(n) {
              age = n
            })
            b.exec()
          }
        }
        class Right {
          var f
          construct(f) {
            this.f = f
          }
          fun exec () {
            f(5)
          }
        }
        fun lambdaVar() {
          var a = Left()
          a.m()
          return a.age
        }
  ''', invokeFunc: 'lambdaVar');
      expect(
        result,
        5,
      );
    });
    test('forward declaration 1', () async {
      final result = await hetu.eval(r'''
      fun forwardDecl1 {
        var i = 42
        var j = i
        i = 4
        return j
      }
  ''', invokeFunc: 'forwardDecl1');
      expect(
        result,
        42,
      );
    });
    test('forward declaration 2', () async {
      final result = await hetu.eval(r'''
      fun forwardDecl2 {
        var i = 42
        i = 4
        var j = i
        return j
      }
  ''', invokeFunc: 'forwardDecl2');
      expect(
        result,
        4,
      );
    });
  });
}