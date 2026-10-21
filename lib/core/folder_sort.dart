enum SortBy { name, date, size }

/// Each folder keeps its own order, including whether directories are grouped.
class FolderSort {
  const FolderSort({this.by = SortBy.name, this.ascending = true, this.foldersFirst = true});

  final SortBy by;
  final bool ascending;
  final bool foldersFirst;

  factory FolderSort.fromJson(Map<dynamic, dynamic> json) => FolderSort(
    by: SortBy.values.firstWhere((value) => value.name == json['by'], orElse: () => SortBy.name),
    ascending: json['ascending'] is bool ? json['ascending'] as bool : true,
    foldersFirst: json['foldersFirst'] is bool ? json['foldersFirst'] as bool : true,
  );

  Map<String, dynamic> toJson() => {'by': by.name, 'ascending': ascending, 'foldersFirst': foldersFirst};
}
