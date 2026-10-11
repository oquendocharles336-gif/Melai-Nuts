import 'package:flutter/material.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../data/repositories/products_repository.dart';

/// Ensures the shared product catalog ([kProducts]/[kProductCategories]) is
/// loaded before showing [builder], retrying the real Supabase fetch if
/// it's still empty (e.g. the app booted offline). The catalog is normally
/// already loaded by the time any screen using this mounts (see
/// `main.dart`), so this is a safety net, not the primary load path.
class CatalogGate extends StatefulWidget {
  final WidgetBuilder builder;
  const CatalogGate({super.key, required this.builder});

  @override
  State<CatalogGate> createState() => _CatalogGateState();
}

class _CatalogGateState extends State<CatalogGate> {
  late final Future<void> _future;

  @override
  void initState() {
    super.initState();
    _future = kProducts.isEmpty ? ProductsRepository.instance.loadCatalog() : Future.value();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _future,
      builder: (context, snapshot) => widget.builder(context),
    );
  }
}
