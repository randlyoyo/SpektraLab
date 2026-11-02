import 'package:flutter/foundation.dart';

import 'stocks.dart';

/// What can be synced from one photo to others, as the Mac app's clipboard groups.
enum Group {
  film('胶片'),
  paper('相纸'),
  exposure('曝光'),
  effects('颗粒与光晕');

  final String label;
  const Group(this.label);
}

/// One photo's develop settings. The defaults are the Mac app's (Params.swift).
@immutable
class Settings {
  final String film, paper;
  final double exposure;
  final bool grain, halation;

  const Settings({
    this.film = 'kodak_portra_400',
    this.paper = 'kodak_supra_endura',
    this.exposure = 0,
    this.grain = true,
    this.halation = true,
  });

  Settings copyWith({String? film, String? paper, double? exposure, bool? grain, bool? halation}) => Settings(
        film: film ?? this.film,
        paper: paper ?? this.paper,
        exposure: exposure ?? this.exposure,
        grain: grain ?? this.grain,
        halation: halation ?? this.halation,
      );

  /// This, with [groups] taken from [from].
  Settings syncedFrom(Settings from, Set<Group> groups) => Settings(
        film: groups.contains(Group.film) ? from.film : film,
        paper: groups.contains(Group.paper) ? from.paper : paper,
        exposure: groups.contains(Group.exposure) ? from.exposure : exposure,
        grain: groups.contains(Group.effects) ? from.grain : grain,
        halation: groups.contains(Group.effects) ? from.halation : halation,
      );

  Map<String, Object> get params => {
        'film_stock': film,
        'print_stock': paper,
        // A slide film is scanned, not printed (the Mac app's film stage rule).
        'scan_film': Stock.byId(film).isPositive,
        'exposure_compensation_ev': exposure,
        'grain_active': grain,
        'halation_active': halation,
      };

  @override
  bool operator ==(Object other) => other is Settings && mapEquals(params, other.params);

  @override
  int get hashCode => Object.hash(film, paper, exposure, grain, halation);
}

class Photo {
  final String id;
  final Uint8List thumb;
  Settings settings = const Settings();
  Uint8List? print, original;
  String status = '';

  /// The settings [print] was made with; differs from [settings] after a sync
  /// to a photo that has not been opened since.
  Settings? printed;

  Photo(this.id, this.thumb);

  bool get edited => settings != const Settings();
  bool get stale => print != null && printed != settings;
}
