import 'package:xml/xml.dart';

class ApplePropertyList {
  const ApplePropertyList._();

  static Map<String, Object?> parseDictionary(String source) {
    final document = XmlDocument.parse(source);
    final plist = document.rootElement;
    final valueElement = plist.childElements.first;
    final value = _parseElement(valueElement);
    if (value is! Map<String, Object?>) {
      throw const FormatException('plist 根节点不是字典');
    }
    return value;
  }

  static Object? _parseElement(XmlElement element) {
    switch (element.name.local) {
      case 'dict':
        final children = element.childElements.toList(growable: false);
        final result = <String, Object?>{};
        for (var index = 0; index < children.length; index += 2) {
          if (children[index].name.local != 'key' ||
              index + 1 >= children.length) {
            throw const FormatException('plist 字典键值不完整');
          }
          result[children[index].innerText] = _parseElement(
            children[index + 1],
          );
        }
        return result;
      case 'array':
        return element.childElements.map(_parseElement).toList(growable: false);
      case 'string':
      case 'date':
      case 'data':
        return element.innerText;
      case 'integer':
        return int.tryParse(element.innerText) ?? 0;
      case 'real':
        return double.tryParse(element.innerText) ?? 0;
      case 'true':
        return true;
      case 'false':
        return false;
      default:
        throw FormatException('不支持的 plist 节点：${element.name.local}');
    }
  }
}
