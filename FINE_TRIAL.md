# r21 Fine 정밀 출력 1차 시험

이번 배포는 진단 확장과 선택적 출력 adapter다. 기본 설정에서는 기존 `setPowerNormalized` 제어를 그대로 사용한다. 모든 Fine 구역을 새 API로 자동 전환하지 않는다. 자세 PD, 각속도 예측 감쇠, Recovery, deadzone(HOVER 0.5° / MOVING 1.0°), Main/Sub/Fine 배분은 유지한다. 자세 Integral/Trim/feed-forward는 추가하지 않았다.

## 먼저 확인한 블랙박스

분석 자료는 2026-10-25 업로드된 r19 블랙박스다. 현재 r20 비행 상태를 새로 측정한 자료는 아니다.

- 약 P=-2.238°, rateP=-0.018°/s, deadzone=1°에서 기존 공식을 재계산한 Pitch 요구량은 약 -0.869다. 같은 기록의 앞쪽 명령 추력 합은 약 6.536, 뒤쪽은 10.012 command-equivalent다. 보정이 0이 아니라 앞 감소/뒤 증가로 나타난다.
- P=-2.386°, rateP=+3.167°/s에서는 0.5초 예측이 deadzone 안으로 들어가 요구량이 0이 된다. 이 경우는 복귀 중 감쇠의 정상 사례다.
- Fine 노드 적용 보고값도 소수로 변했다. 다만 보고가 명령보다 약 0.3~0.7초 뒤처지고 명령 번호가 일치하는 실측 비교가 아니므로, 이전 기록만으로 peripheral 전달 실패나 실제 추력 해상도를 확정할 수 없다.
- 위 요구량은 이전 로그의 각도/각속도를 기존 공식으로 재계산한 값이다. r21부터는 실제 사용한 PD 요구와 Recovery 반영 후 명령을 제어 sequence와 함께 저장한다.
- 현재 기준 전체 모드 로그 `latest(20261012-091812).log`의 Mod List는 CC:Tweaked 1.118.0 / Propulsion 1.1.4 / Avionics 0.4.0을 기록한다. 이후 실제 설치 변경 여부 및 실제 메서드 목록은 게임 내에서 다시 확인해야 한다.

## r21 진단값

11번의 기존 순환 블랙박스에 다음 값이 추가된다.

- `attitude.demand`: 실제 PD roll/pitch, 최종 command, 예측 각도, deadzone, motionMode, sensorTime, seq, ARM/Recovery.
- 구역별 `signed`, `targetCorrection`, `correction`, target/total/phase와 기존 Main/Sub/Fine 요청값.
- 노드 `acceptedSeq`, `appliedSeq`, `requestedAtWrite`, 기존 적용 보고와 `fineAdapter` 상태.
- adapter의 `requested`는 목표값, `accepted`는 성공한 API 쓰기의 정규화 값이다. 물리 추력 측정값이 아니다. 선택적 `reported`도 peripheral의 보고값이며 실제 추력 측정으로 간주하지 않는다.
- `FINE_ADAPTER` 이벤트는 런타임 peripheral 타입/메서드 목록과 선택 경로를 기록한다. 요청하지 않은 새 actuator 메서드를 자동 호출하지 않는다.
- `STEADY_ERROR / DEMAND_PRESENT`, `CHECK_DEMAND`, `RATE_DAMPED`, hunting/saturation 상태는 진단용이다. 이 상태가 PD gain을 자동 변경하지 않는다. 기존 Recovery가 실제 안전제어를 계속 담당한다.

모니터의 기존 진단 페이지(스크롤)에 위 상태, signed/correction, 출력 경로, sequence가 표시된다. Fine 퍼센트는 소수 3자리까지 표시한다. 화면에 작은 숫자가 보인다는 이유만으로 실제 추진기 해상도가 개선됐다고 판단하지 않는다.

## 런타임 목록 확인

안전하게 정지한 상태에서 별도 shell/tab 또는 시험 CC에서 `fleet fine_inspect`를 실행하면 장치의 실제 타입과 메서드를 표시하고 `fleet_fine_inventory.txt`에 저장한다. 이 명령은 actuator 메서드를 호출하지 않는다. 실행 중인 `fleet_admin`/비행 프로그램을 강제로 중단하는 절차를 자동 수행하지 않는다.

각 Fine 노드의 시작/재점검 때도 기존 블랙박스에 메서드 목록이 기록된다. 기존 출력이 정상적으로 사용하는 `setPowerNormalized` 외에 새 Propulsion 메서드 이름은 코드에 고정하지 않았다.

## 한 Fine 구역만 선택해 시험

실제 장치의 메서드·단위·안전한 0 출력·기존 경로와의 호환을 확인한 뒤, 선택한 노드에만 `fleet.fine_adapter` 설정을 저장한다. 설정은 코드 배포로 덮어쓰지 않는 기존 CC settings에 남는다. ADMIN STOP으로 함선을 안전하게 정지한 뒤 해당 노드의 정상 재시작/재점검 절차로 반영한다.

설정 형식(값을 확인한 후 채우는 템플릿이며 그대로 활성화하는 예제가 아님):

```lua
{
  enabled = true,
  pilotComputer = 16, -- 논리 역할 번호가 아닌 실제 Computer ID 한 개
  scope = 'SINGLE_ZONE_TEST',
  confirmed = true,
  fallbackCompatible = true,
  risePerSecond = 2.75,
  fallPerSecond = 3.5,
  writeEpsilon = 0.000001,
  devices = {
    ['실제_Fine_장치명'] = {
      method = '런타임에서_확인한_절대출력_메서드',
      zero = 0, -- 확인한 실제 단위의 0 출력
      full = 1, -- 확인한 실제 단위의 최대 출력
      absolute = true
    }
    -- 해당 구역의 실제 Fine 장치를 모두 명시
  }
}
```

- `confirmed`는 사용자가 메서드와 출력 범위를 시험했다는 선언이다. 소프트웨어가 물리 추력 시험을 대신했다는 뜻이 아니다.
- `fallbackCompatible`는 기존 `setPowerNormalized`가 같은 actuator의 출력을 확실하게 덮어쓰고 0으로 만들 수 있다는 확인이다. 서로 다른 출력이 가산되는 API라면 이 adapter로 활성화하지 않는다.
- 이 adapter는 단일 값 인자의 절대출력 setter와, 선택적 무인자 read-only getter만 지원한다. 다인자·증분·펄스·다른 제어계와 가산되는 API는 이 시험 경로에 넣지 않는다.
- 범위는 메서드마다 다를 수 있다. 0~1 또는 0~100이라고 추정해서 넣지 않는다. 0~1 목표를 확인한 `zero`~`full` 단위로 변환한다.
- 한 실제 ID만 활성화된다. 다른 CC에 같은 설정이 복사돼도 자동으로 정밀 모드에 들어가지 않는다. 장치 누락, 미확인 메서드, 미확인 설정은 기존 fallback을 유지한다.
- 설정된 메서드가 런타임 목록에 있어도 인자 의미·단위·물리 해상도까지 검증된 것은 아니다. 먼저 낮은 출력으로 실기 비교해야 한다.
- 상승은 기존 CFG.fineRise 이하, 하강은 CFG.fineFall 이상으로 제한한다. STOP/DISARM/FAULT/watchdog의 0 출력은 slew를 기다리지 않는다.
- 새 쓰기가 실패하면 해당 actuator는 기존 메서드로 되돌아가고, 다음 재점검까지 새 메서드를 반복 재시도하지 않는다. fallback 중에도 시험 경로의 상승 제한을 유지해 출력 점프를 피한다. 기존 경로마저 실패하면 기존 노드 FAULT 처리를 따른다.
- 선택적 readback은 `readback={method='실제 getter',zero=...,full=...,readOnlyConfirmed=true}`로 명시한다. 확인하지 않은 getter를 이름으로 추측해 호출하지 않는다.
- 정밀 경로를 끄려면 `fleet.fine_adapter.enabled=false`로 저장하고 안전 정지 후 재점검한다.

## 실기 비교 순서와 남은 확인

1. 정밀 경로를 끈 상태의 r21 로그로 P/R 2.x° 정체 구간을 기록한다.
2. 해당 구간의 각속도·PD 요구·signed·구역 target/total·노드 요청/accepted·sequence/age를 함께 본다.
3. 한 구역 또는 별도 시험기에서만 정밀 경로를 켜고 같은 조건을 비교한다. 추가 slew 때문에 기존 cross-fade의 명령 추력과 노드 accepted 값에 차이가 생길 수 있으므로 그 차이도 확인한다.
4. 정지, 작은 기울기, 빠른 복귀, 이동 외란, 새 API 실패 시 fallback, ADMIN STOP을 순서대로 확인한다.
5. 물리 추력 해상도, overshoot, 진동, 잔류 편향이 개선됐는지 판단한다. 개선이 확인되기 전에는 전체 Fine 확대·deadzone 축소·I/Trim 추가를 하지 않는다.

이 환경에서는 실제 Minecraft peripheral이나 물리 추력에 접근할 수 없으므로 런타임 메서드 확인과 실제 비행 성능은 미검증이다. r21의 기본 배포는 진단 수집 단계이며, 정체 현상이 이미 해결됐다고 주장하지 않는다.
