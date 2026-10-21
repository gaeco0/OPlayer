import 'dart:collection';
import 'dart:convert';

import 'package:html/dom.dart' as html;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

/// Documents are scoped to one plugin invocation and never load external data.
class PluginParser {
  final _nodes = <int, ({Object node, int document})>{};
  final _handles = HashMap<Object, int>.identity();
  var _sequence = 0, _documents = 0, _characters = 0;

  Object? call(Map args) {
    final method = args['method'];
    if (method == 'html' || method == 'xml') {
      final text = args['text'];
      if (text is! String || text.length > 1024 * 1024) throw const FormatException('파서 입력은 1Mi 글자 이하여야 합니다');
      if (_documents >= 16 || _characters + text.length > 8 * 1024 * 1024) {
        throw StateError('확장앱 파서 문서 한도 초과');
      }
      final Object document;
      if (method == 'html') {
        document = html_parser.parse(text);
      } else {
        if (RegExp(r'<!\s*(DOCTYPE|ENTITY)\b', caseSensitive: false).hasMatch(text)) {
          throw const FormatException('XML DTD·엔티티 선언은 지원하지 않습니다');
        }
        try {
          document = XmlDocument.parse(text);
        } on XmlException {
          throw const FormatException('올바르지 않은 XML 문서');
        }
      }
      // Bound native memory and traversal depth before exposing a document.
      final pending = <(Object, int)>[(document, 0)];
      var count = 0;
      while (pending.isNotEmpty) {
        final (node, depth) = pending.removeLast();
        if (++count > 20000 || depth > 128) throw const FormatException('파서 문서 크기·깊이 한도 초과');
        for (final child in _children(node)) {
          pending.add((child, depth + 1));
        }
      }
      _documents++;
      _characters += text.length;
      return _snapshot(document, ++_sequence);
    }
    final entry = _nodes[args['handle']];
    if (entry == null) throw StateError('만료되거나 잘못된 파서 문서');
    final node = entry.node;
    if (method == 'dispose') {
      final removed = _nodes.values
          .where((value) => value.document == entry.document)
          .map((value) => value.node)
          .toList();
      _nodes.removeWhere((_, value) => value.document == entry.document);
      removed.forEach(_handles.remove);
      return null;
    }
    Iterable<Object> matches;
    if (method == 'children') {
      matches = _children(node).where((child) => child is html.Element || child is XmlElement);
    } else if (method == 'querySelector' || method == 'querySelectorAll') {
      if (node is! html.Node) throw StateError('CSS 선택자는 HTML 문서에서 사용해 주세요');
      final selector = args['selector'];
      if (selector is! String || selector.isEmpty || selector.length > 1024) {
        throw const FormatException('잘못된 CSS 선택자');
      }
      final List<html.Element> selected = switch (node) {
        html.Document node =>
          method == 'querySelector'
              ? [if (node.querySelector(selector) case final html.Element element) element]
              : node.querySelectorAll(selector),
        html.Element node =>
          method == 'querySelector'
              ? [if (node.querySelector(selector) case final html.Element element) element]
              : node.querySelectorAll(selector),
        _ => throw StateError('잘못된 HTML 노드'),
      };
      matches = selected;
    } else if (method == 'findElements' || method == 'findAllElements') {
      if (node is! XmlNode) throw StateError('XML 태그 조회는 XML 문서에서 사용해 주세요');
      final name = args['name'];
      final namespace = args['namespace'];
      if (name is! String || name.isEmpty || name.length > 1024 || (namespace != null && namespace is! String)) {
        throw const FormatException('잘못된 XML 이름·네임스페이스');
      }
      matches = method == 'findElements'
          ? node.findElements(name, namespace: namespace as String?)
          : node.findAllElements(name, namespace: namespace as String?);
    } else {
      throw StateError('지원하지 않는 파서 메서드');
    }
    final result = matches.take(2001).toList();
    if (result.length > 2000) throw StateError('파서 조회 결과는 2000개 이하여야 합니다');
    final snapshots = result.map((value) => _snapshot(value, entry.document)).toList();
    if (jsonEncode(snapshots).length > 2 * 1024 * 1024) throw StateError('파서 조회 결과 크기 한도 초과');
    return method == 'querySelector' ? snapshots.firstOrNull : snapshots;
  }

  Iterable<Object> _children(Object node) => switch (node) {
    html.Node node => node.nodes,
    XmlNode node => node.children,
    _ => const [],
  };

  Map<String, Object?> _snapshot(Object node, int document) {
    if (_nodes.length >= 20000 && !_handles.containsKey(node)) throw StateError('파서 노드 한도 초과');
    final handle = _handles.putIfAbsent(node, () => ++_sequence);
    _nodes[handle] = (node: node, document: document);
    return switch (node) {
      html.Node node => {
        'handle': handle,
        'name': node is html.Element ? node.localName : '#document',
        'localName': node is html.Element ? node.localName : null,
        'namespaceUri': node is html.Element ? node.namespaceUri : null,
        'attributes': node is html.Element ? {for (final e in node.attributes.entries) '${e.key}': e.value} : {},
        'textContent': node is html.Document ? node.documentElement?.text ?? '' : node.text ?? '',
      },
      XmlNode node => {
        'handle': handle,
        'name': node is XmlElement ? node.name.qualified : '#document',
        'localName': node is XmlElement ? node.name.local : null,
        'namespaceUri': node is XmlElement ? node.namespaceUri : null,
        'attributes': {for (final a in node.attributes) a.name.qualified: a.value},
        'textContent': node.innerText,
      },
      _ => throw StateError('잘못된 파서 노드'),
    };
  }
}

/// Same read-only facade in QuickJS and page hooks; DOM queries are asynchronous.
const pluginParserFactory = r'''
function createOPlayerParser(invoke) {
  const wrap = value => {
    if (value == null) return null;
    const {handle, ...data} = value;
    const query = async (method, args = {}) => invoke({method, handle, ...args});
    return Object.freeze({...data, attributes: Object.freeze(data.attributes),
      getAttribute: name => Object.hasOwn(data.attributes, name) ? data.attributes[name] : null,
      querySelector: async selector => wrap(await query('querySelector', {selector})),
      querySelectorAll: async selector => (await query('querySelectorAll', {selector})).map(wrap),
      findElements: async (name, namespace = null) => (await query('findElements', {name, namespace})).map(wrap),
      findAllElements: async (name, namespace = null) => (await query('findAllElements', {name, namespace})).map(wrap),
      children: async () => (await query('children')).map(wrap),
      dispose: () => query('dispose')
    });
  };
  const checked = text => {
    if (typeof text !== 'string' || text.length > 1048576) throw new Error('파서 입력은 1Mi 글자 이하여야 합니다');
    return text;
  };
  return Object.freeze({
    json: text => JSON.parse(checked(text)),
    html: async text => wrap(await invoke({method:'html', text:checked(text)})),
    xml: async text => wrap(await invoke({method:'xml', text:checked(text)}))
  });
}
''';

/// Page hooks use the browser's inert DOM parser, without inserting parsed nodes.
const pluginPageParser = r'''
function createOPlayerPageParser() {
  const nodes = new Map(), handles = new WeakMap();
  let sequence = 0, documents = 0, characters = 0;
  const children = node => Array.from(node.childNodes);
  const snapshot = (node, document) => {
    if (!handles.has(node)) {
      if (nodes.size >= 20000) throw new Error('파서 노드 한도 초과');
      handles.set(node, ++sequence);
    }
    const handle = handles.get(node);
    nodes.set(handle, {node, document});
    return {handle, name:node.nodeType === 9 ? '#document' : (node.ownerDocument.contentType === 'text/html' ? node.localName : node.nodeName),
      localName:node.localName || null, namespaceUri:node.namespaceURI || null,
      attributes:Object.fromEntries(Array.from(node.attributes || [], a => [a.name,a.value])),
      textContent:(node.nodeType === 9 ? node.documentElement : node).textContent || ''};
  };
  return createOPlayerParser(async args => {
    const {method} = args;
    if (method === 'html' || method === 'xml') {
      if (documents >= 16 || characters + args.text.length > 8388608) throw new Error('확장앱 파서 문서 한도 초과');
      if (method === 'xml' && /<!\s*(DOCTYPE|ENTITY)\b/i.test(args.text)) throw new Error('XML DTD·엔티티 선언은 지원하지 않습니다');
      const doc = new DOMParser().parseFromString(args.text, method === 'html' ? 'text/html' : 'application/xml');
      if (method === 'xml' && doc.querySelector('parsererror')) throw new Error('올바르지 않은 XML 문서');
      const pending = [[doc,0]];
      let count = 0;
      while (pending.length) {
        const [node,depth] = pending.pop();
        if (++count > 20000 || depth > 128) throw new Error('파서 문서 크기·깊이 한도 초과');
        for (const child of children(node)) pending.push([child,depth+1]);
      }
      ++documents; characters += args.text.length;
      return snapshot(doc, ++sequence);
    }
    const entry = nodes.get(args.handle);
    if (!entry) throw new Error('만료되거나 잘못된 파서 문서');
    const {node,document} = entry;
    if (method === 'dispose') {
      for (const [id,e] of nodes) if (e.document === document) { handles.delete(e.node); nodes.delete(id); }
      return null;
    }
    let result;
    if (method === 'children') result = children(node).filter(n => n.nodeType === 1);
    else if (method === 'querySelector' || method === 'querySelectorAll') {
      if (node.ownerDocument?.contentType === 'application/xml' || node.contentType === 'application/xml') throw new Error('CSS 선택자는 HTML 문서에서 사용해 주세요');
      if (typeof args.selector !== 'string' || !args.selector || args.selector.length > 1024) throw new Error('잘못된 CSS 선택자');
      result = method === 'querySelector' ? [node.querySelector(args.selector)].filter(Boolean) : Array.from(node.querySelectorAll(args.selector));
    } else if (method === 'findElements' || method === 'findAllElements') {
      if ((node.ownerDocument || node).contentType !== 'application/xml') throw new Error('XML 태그 조회는 XML 문서에서 사용해 주세요');
      if (typeof args.name !== 'string' || !args.name || args.name.length > 1024 || (args.namespace != null && typeof args.namespace !== 'string')) throw new Error('잘못된 XML 이름·네임스페이스');
      result = method === 'findElements' ? children(node).filter(n => n.nodeType === 1) : Array.from(node.getElementsByTagName('*'));
      result = result.filter(n => args.namespace == null ? args.name === '*' || n.nodeName === args.name :
        (args.namespace === '*' || n.namespaceURI === args.namespace) && (args.name === '*' || n.localName === args.name));
    } else throw new Error('지원하지 않는 파서 메서드');
    if (result.length > 2000) throw new Error('파서 조회 결과는 2000개 이하여야 합니다');
    const values = result.map(n => snapshot(n,document));
    if (JSON.stringify(values).length > 2097152) throw new Error('파서 조회 결과 크기 한도 초과');
    return method === 'querySelector' ? values[0] || null : values;
  });
}
''';
