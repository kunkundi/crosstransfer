// Desktop activity counts shared by navigation, status and transfer history.
// Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

const _runningStates = {
  'claiming',
  'connecting',
  'offering',
  'waiting_offer',
  'transferring',
  'verifying',
};

final transferActivityProvider = Provider<({int sending, int receiving})>(
  (ref) => ref.watch(
    coreStateProvider.select(
      (state) => (
        sending: state.transfers.values
            .where(
              (transfer) =>
                  transfer.role == 'sender' &&
                  _runningStates.contains(transfer.state),
            )
            .length,
        // Receive records include claims before a transport exists. Counting the
        // receiver transport as well would count the same operation twice.
        receiving: state.receives.values
            .where((receive) => _runningStates.contains(receive.state))
            .length,
      ),
    ),
  ),
);
