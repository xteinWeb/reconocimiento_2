import 'dart:io';
import 'dart:typed_data';
import 'package:excel/excel.dart' as excel_pkg;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/database_service.dart';
import '../theme/app_colors.dart';
import 'enrollment_screen.dart';

/// Quién puede marcar por rostro y quién no.
///
/// Valida plantilla por plantilla con el MISMO criterio que usa el
/// reconocimiento, así que lo que aquí aparece como "Enrolado" es exactamente
/// lo que el tótem puede identificar. Responde con nombres y cédulas, no con
/// un conteo, para que RRHH pueda ir a buscar a la gente.
class EnrollmentStatusScreen extends StatefulWidget {
  const EnrollmentStatusScreen({super.key});

  @override
  State<EnrollmentStatusScreen> createState() => _EnrollmentStatusScreenState();
}

class _EnrollmentStatusScreenState extends State<EnrollmentStatusScreen> {
  final _database = DatabaseService();
  final _searchController = TextEditingController();

  List<EnrollmentStatus> _todos = [];
  bool _cargando = true;
  String _busqueda = '';
  String _filtro = 'Requieren acción';
  String _seccion = 'Todas';
  List<String> _secciones = ['Todas'];

  static const List<String> _filtros = [
    'Requieren acción',
    'Todos',
    'Sin enrolar',
    'Plantillas inválidas',
    'Sin pose frontal',
    'Incompletos',
    'Enrolados',
  ];

  @override
  void initState() {
    super.initState();
    _cargar();
    _searchController.addListener(() {
      setState(() => _busqueda = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final lista = await _database.obtenerEstadoEnrolamiento();
      final secciones = <String>{};
      for (final s in lista) {
        final d = s.employee.department;
        if (d != null && d.isNotEmpty) secciones.add(d);
      }
      if (!mounted) return;
      setState(() {
        _todos = lista;
        _secciones = ['Todas', ...secciones.toList()..sort()];
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _cargando = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al cargar: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  // ------------------------------------------------------------------
  // Filtrado
  // ------------------------------------------------------------------

  bool _pasaFiltro(EnrollmentStatus s) {
    switch (_filtro) {
      case 'Todos':
        return true;
      case 'Requieren acción':
        return s.requiereReenrolamiento ||
            s.nivel == NivelEnrolamiento.incompleto;
      case 'Sin enrolar':
        return s.nivel == NivelEnrolamiento.nuncaEnrolado;
      case 'Plantillas inválidas':
        return s.nivel == NivelEnrolamiento.invalido;
      case 'Sin pose frontal':
        return s.nivel == NivelEnrolamiento.sinFrontal;
      case 'Incompletos':
        return s.nivel == NivelEnrolamiento.incompleto;
      case 'Enrolados':
        return s.nivel == NivelEnrolamiento.ok;
      default:
        return true;
    }
  }

  List<EnrollmentStatus> get _filtrados => _todos.where((s) {
    if (!_pasaFiltro(s)) return false;

    if (_seccion != 'Todas' && s.employee.department != _seccion) return false;

    if (_busqueda.isNotEmpty) {
      final nombre = s.employee.name.toLowerCase();
      final codigo = s.employee.employeeCode.toLowerCase();
      if (!nombre.contains(_busqueda) && !codigo.contains(_busqueda)) {
        return false;
      }
    }
    return true;
  }).toList();

  int _contar(NivelEnrolamiento nivel) =>
      _todos.where((s) => s.nivel == nivel).length;

  // ------------------------------------------------------------------
  // Exportación
  // ------------------------------------------------------------------

  excel_pkg.CellValue _cell(dynamic v) {
    if (v == null) return excel_pkg.TextCellValue('');
    if (v is int) return excel_pkg.IntCellValue(v);
    if (v is double) return excel_pkg.DoubleCellValue(v);
    return excel_pkg.TextCellValue(v.toString());
  }

  Future<void> _exportar() async {
    final datos = _filtrados;
    if (datos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay colaboradores en el filtro actual.'),
          backgroundColor: AppColors.primary,
        ),
      );
      return;
    }

    setState(() => _cargando = true);

    try {
      final excel = excel_pkg.Excel.createExcel();
      final hoja = excel[excel.getDefaultSheet() ?? 'Sheet1'];

      hoja.appendRow(
        [
          'Cédula',
          'Nombre',
          'Sección',
          'Estado',
          'Requiere re-enrolar',
          'Plantillas válidas',
          'Plantillas inválidas',
          'Poses frontales válidas',
          'Poses guardadas',
          'Detalle',
        ].map(_cell).toList(),
      );

      for (final s in datos) {
        hoja.appendRow(
          [
            s.employee.employeeCode,
            s.employee.name,
            s.employee.department ?? '',
            s.etiqueta,
            s.requiereReenrolamiento ? 'SÍ' : 'No',
            s.plantillasValidas,
            s.plantillasInvalidas,
            s.frontalesValidas,
            (s.posesValidas.toList()..sort()).join(', '),
            s.explicacion,
          ].map(_cell).toList(),
        );
      }

      final bytes = excel.encode();
      if (bytes == null) throw Exception('No se pudo generar el archivo.');

      final stamp = DateFormat('yyyyMMdd').format(DateTime.now());
      final destino = await FilePicker.platform.saveFile(
        dialogTitle: 'Guardar estado de enrolamiento',
        fileName: 'Estado_Enrolamiento_$stamp.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        bytes: Uint8List.fromList(bytes),
      );

      if (!mounted) return;
      setState(() => _cargando = false);

      if (destino != null) {
        final file = File(destino);
        if (!await file.exists()) await file.writeAsBytes(bytes);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Exportado: ${datos.length} colaboradores.'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _cargando = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al exportar: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  Future<void> _enrolar(EnrollmentStatus s) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EnrollmentScreen(employee: s.employee),
      ),
    );
    _cargar();
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  Color _color(NivelEnrolamiento nivel) => switch (nivel) {
    NivelEnrolamiento.ok => AppColors.success,
    NivelEnrolamiento.incompleto => Colors.orange,
    NivelEnrolamiento.sinFrontal => AppColors.error,
    NivelEnrolamiento.invalido => AppColors.error,
    NivelEnrolamiento.nuncaEnrolado => Colors.grey,
  };

  IconData _icono(NivelEnrolamiento nivel) => switch (nivel) {
    NivelEnrolamiento.ok => Icons.verified_user_rounded,
    NivelEnrolamiento.incompleto => Icons.pending_actions_rounded,
    NivelEnrolamiento.sinFrontal => Icons.face_retouching_off_rounded,
    NivelEnrolamiento.invalido => Icons.report_problem_rounded,
    NivelEnrolamiento.nuncaEnrolado => Icons.person_off_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lista = _filtrados;

    return Scaffold(
      backgroundColor: isDark
          ? AppColors.kioskBackground
          : AppColors.background,
      appBar: AppBar(
        title: const Text('Estado de Enrolamiento'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: isDark ? Colors.white : Colors.black,
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            onPressed: _cargando ? null : _cargar,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Exportar a Excel',
            onPressed: _cargando ? null : _exportar,
            icon: const Icon(Icons.file_download_outlined),
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _resumen(isDark),
                _controles(isDark),
                Expanded(
                  child: lista.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text(
                              'No hay colaboradores que coincidan con el filtro.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey),
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          itemCount: lista.length,
                          itemBuilder: (_, i) => _fila(lista[i], isDark),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _resumen(bool isDark) {
    final pendientes = _todos.where((s) => s.requiereReenrolamiento).length;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.kioskSurface : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                pendientes == 0
                    ? Icons.check_circle_rounded
                    : Icons.warning_amber_rounded,
                color: pendientes == 0 ? AppColors.success : AppColors.error,
                size: 26,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  pendientes == 0
                      ? 'Todos los colaboradores pueden marcar por rostro.'
                      : '$pendientes colaborador(es) NO pueden marcar por rostro.',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip(
                'Enrolados',
                _contar(NivelEnrolamiento.ok),
                AppColors.success,
              ),
              _chip(
                'Incompletos',
                _contar(NivelEnrolamiento.incompleto),
                Colors.orange,
              ),
              _chip(
                'Sin frontal',
                _contar(NivelEnrolamiento.sinFrontal),
                AppColors.error,
              ),
              _chip(
                'Inválidas',
                _contar(NivelEnrolamiento.invalido),
                AppColors.error,
              ),
              _chip(
                'Sin enrolar',
                _contar(NivelEnrolamiento.nuncaEnrolado),
                Colors.grey,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String texto, int n, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withOpacity(0.4)),
    ),
    child: Text(
      '$texto: $n',
      style: TextStyle(
        fontSize: 12,
        color: color,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  Widget _controles(bool isDark) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    child: Column(
      children: [
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Buscar por nombre o cédula',
            prefixIcon: const Icon(Icons.search),
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _filtro,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Estado',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                items: _filtros
                    .map(
                      (f) => DropdownMenuItem(
                        value: f,
                        child: Text(f, style: const TextStyle(fontSize: 13)),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _filtro = v ?? 'Todos'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _secciones.contains(_seccion) ? _seccion : 'Todas',
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Sección',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                items: _secciones
                    .map(
                      (s) => DropdownMenuItem(
                        value: s,
                        child: Text(s, style: const TextStyle(fontSize: 13)),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _seccion = v ?? 'Todas'),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _fila(EnrollmentStatus s, bool isDark) {
    final color = _color(s.nivel);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: isDark ? AppColors.kioskSurface : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withOpacity(0.35)),
      ),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(_icono(s.nivel), color: color, size: 30),
        title: Text(
          s.employee.name,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${s.employee.employeeCode}  •  ${s.employee.department ?? "Sin sección"}',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            s.etiqueta,
            style: TextStyle(
              fontSize: 10,
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.explicacion,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 10),
                Text(
                  'Poses válidas: '
                  '${s.posesValidas.isEmpty ? "ninguna" : (s.posesValidas.toList()..sort()).join(", ")}'
                  '${s.plantillasInvalidas > 0 ? "   •   ${s.plantillasInvalidas} descartada(s)" : ""}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: s.requiereReenrolamiento
                          ? AppColors.primary
                          : Colors.grey.shade600,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: () => _enrolar(s),
                    icon: const Icon(Icons.camera_alt_rounded, size: 18),
                    label: Text(
                      s.plantillasTotales == 0
                          ? 'Enrolar ahora'
                          : 'Re-enrolar ahora',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
