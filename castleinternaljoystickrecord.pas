unit CastleInternalJoystickRecord;

interface

uses
  Generics.Collections;

type
  TJoystickEvent = (
    { The event was not detected, in other words, it means an error }
    unknownEvent, unknownAxisEvent, unknownButtonEvent,

    { Primary pad buttons }
    padX, padY, padA, padB,

    { Utility buttons }
    buttonBack, buttonStart,

    { Shoulder buttons }
    buttonRightShoulder, buttonLeftShoulder,
    buttonRightTrigger, buttonLeftTrigger,

    { Primary axes }
    axisLeftX, axisLeftY,
    axisRightX, axisRightY,
    axisLeftXPlus, axisLeftXMinus, axisLeftYPlus, axisLeftYMinus,
    axisRightYPlus, axisRightYMinus, {note: there are no RightXPlus/minux events in the database }

    { Pressing on the sticks }
    buttonLeftStick, buttonRightStick,

    { D-Pad buttons/axes }
    dpadLeft, dpadRight, dpadUp, dpadDown,

    { X-Box button }
    buttonGuide

    );

type
  { Represents "Primary" event that had been pressed and
    "Inverse" event that possibly had been released
    In other words, if we have an axis assigned to two events -
    EventA (Axis.Value > 0) and EventB (Axis.Value < 0)
    then we have to release both EventA and EventB in case Axis.Value = 0 }
  TJoystickEventPair = record
    Primary, Inverse: TJoystickEvent;
  end;

const
  AxisEvents = [axisLeftX, axisLeftY, axisRightX, axisRightY,
    axisLeftXPlus, axisLeftXMinus, axisLeftYPlus, axisLeftYMinus,
    axisRightYPlus, axisRightYMinus];

type
  TJoystickDictionary = specialize TDictionary<Byte, TJoystickEvent>;
  TInvertAxes = specialize TList<Byte>;

type
  TJoystickLayout = class
  strict private
    type
      TSetOfJoystickEvents = set of TJoystickEvent;
    var
      FJoystickHasEvents: TSetOfJoystickEvents;
  public
    { GUID of the joystick in the database, unused for now }
    Guid: String;
    { Which number of event (button/axis/pad) corresponds to which joystick event
      Note that some joysticks are tricky and have buttons assigned to axes
      or D-Pad to buttons }
    Buttons, AxesPlus, AxesMinus, DPad: TJoystickDictionary;
    {}
    InvertAxes: TInvertAxes;
    { Reported name of the joystick. Note, that currently our backend reports
      different joystick names, especially on Windows, where it often simply
      reports 'Microsoft PC-joystick driver' }
    JoystickName: String;
    { This joystick was reported as "buggy",
      sharing the same GUID with other joysticks with different axes/buttons layouts }
    BuggyGuid: Boolean;
    { The database for this joystick has duplicate entries for the same event
      e.g. axis[0] is reported as both LeftX and RightX.
      This means the data for this joystick is unreliable }
    BuggyDuplicateEvents: Boolean;
    BuggyDuplicateAxes: Boolean;
    function MakeCopy: TJoystickLayout;
    { Translate axis, D-Pads and button events reported by Backend to TJoystickEvent }
    function InvertAxis(const AxisID: Byte): Boolean;
    function ButtonEvent(const ButtonID: Byte): TJoystickEvent;
    function AxisEvent(const AxisID: Byte; const AxisValue: Single): TJoystickEventPair;
    function DPadEvent(const DPadAxis: Byte; const AxisValue: Single): TJoystickEventPair;

    { Report if the joystick has a specific feature }
    property JoystickHasEvents: TSetOfJoystickEvents read FJoystickHasEvents;
    function HasLeftStick: Boolean;
    function HasRightStick: Boolean;
    function HasDPad: Boolean;
    function HasAbyx: Boolean;
    procedure CacheJoystickEvents;
    function LogJoystickFeatures: String;

    constructor Create; //override;
    destructor Destroy; override;
  end;

  TJoystickDatabase = specialize TObjectDictionary<String, TJoystickLayout>;

  { Database of joysticks by name/GUID,
    A database corresponding to the current OS will be loaded
    As different OS report different GUIDs and names for the same joystick }
var
  JoystickRecordsByName, JoystickRecordsByGuid: TJoystickDatabase;

function JoystickEventToStr(const Event: TJoystickEvent): String;
implementation
uses
  Classes, SysUtils,
  CastleLog, CastleUtils;

{ TJoystickLayout ---------------------------------------------------------}

constructor TJoystickLayout.Create;
begin
  inherited; //parent is empty
  BuggyGuid := false;
  BuggyDuplicateEvents := false;
  BuggyDuplicateAxes := false;
  Buttons := TJoystickDictionary.Create;
  AxesPlus := TJoystickDictionary.Create;
  AxesMinus := TJoystickDictionary.Create;
  DPad := TJoystickDictionary.Create;
end;

destructor TJoystickLayout.Destroy;
begin
  FreeAndNil(Buttons);
  FreeAndNil(AxesPlus);
  FreeAndNil(AxesMinus);
  FreeAndNil(DPad);
  FreeAndNil(InvertAxes);
  inherited;
end;

function TJoystickLayout.MakeCopy: TJoystickLayout;
var
  B: Byte;
begin
  Result := TJoystickLayout.Create;
  Result.JoystickName := JoystickName;
  Result.Guid := Guid;
  Result.BuggyGuid := BuggyGuid;
  Result.BuggyDuplicateEvents := BuggyDuplicateEvents;
  Result.BuggyDuplicateAxes := BuggyDuplicateAxes;
  for B in Buttons.Keys do
    Result.Buttons.Add(B, Buttons[B]);
  for B in AxesPlus.Keys do
    Result.AxesPlus.Add(B, AxesPlus[B]);
  for B in AxesMinus.Keys do
    Result.AxesMinus.Add(B, AxesMinus[B]);
  for B in DPad.Keys do
    Result.DPad.Add(B, DPad[B]);
  if InvertAxes <> nil then
  begin
    Result.InvertAxes := TInvertAxes.Create;
    for B in InvertAxes do
      Result.InvertAxes.Add(B);
  end;
  Result.CacheJoystickEvents;
end;

function TJoystickLayout.InvertAxis(const AxisID: Byte): Boolean;
begin
  if (InvertAxes <> nil) and (InvertAxes.Contains(AxisID)) then
    Result := true
  else
    Result := false;
end;

function TJoystickLayout.AxisEvent(const AxisID: Byte; const AxisValue: Single): TJoystickEventPair;
var
  PositiveEvent, NegativeEvent: TJoystickEvent;
begin
  if not AxesPlus.TryGetValue(AxisID, PositiveEvent) then
    PositiveEvent := unknownAxisEvent;
  if not AxesMinus.TryGetValue(AxisID, NegativeEvent) then
    NegativeEvent := unknownAxisEvent;

  if AxisValue >= 0 then
  begin
    Result.Primary := PositiveEvent;
    Result.Inverse := NegativeEvent;
  end else
  begin
    Result.Primary := NegativeEvent;
    Result.Inverse := PositiveEvent;
  end;
end;

function TJoystickLayout.DPadEvent(const DPadAxis: Byte; const AxisValue: Single): TJoystickEventPair;
begin
  if DPadAxis = 6 then
  begin
    //D-Pad X axis
    if AxisValue >= 0 then
    begin
      Result.Primary := dpadRight;
      Result.Inverse := dpadLeft;
    end else
    begin
      Result.Primary := dpadLeft;
      Result.Inverse := dpadRight;
    end;
  end else
  if DPadAxis = 7 then
  begin
    //D-Pad Y axis
    if AxisValue >= 0 then
    begin
      Result.Primary := dpadDown;
      Result.Inverse := dpadUp;
    end else
    begin
      Result.Primary := dpadUp;
      Result.Inverse := dpadDown;
    end;
  end else
    raise Exception.Create('Error: TJoystickLayout.DPadEvent received an unexpected axis = ' + IntToStr(DPadAxis));

  {begin
    DPad.TryGetValue()
  end;}
end;

function TJoystickLayout.ButtonEvent(const ButtonID: Byte): TJoystickEvent;
begin
  if not Buttons.TryGetValue(ButtonID, Result) then
    Result := unknownButtonEvent;
end;

procedure TJoystickLayout.CacheJoystickEvents;
  procedure ScanDictionary(const ADictionary: TJoystickDictionary);
  var
    B: Byte;
  begin
    for B in ADictionary.Keys do
      Include(FJoystickHasEvents, ADictionary.Items[B]);
  end;
begin
  FJoystickHasEvents := [];
  ScanDictionary(Buttons);
  ScanDictionary(AxesPlus);
  ScanDictionary(AxesMinus);
  ScanDictionary(DPad);
end;

function TJoystickLayout.HasLeftStick: Boolean;
begin
  Result :=
    ((axisLeftX in JoystickHasEvents) or
    ((axisLeftXPlus in JoystickHasEvents) and (axisLeftXMinus in JoystickHasEvents))) and
    ((axisLeftY in JoystickHasEvents) or
    ((axisLeftYPlus in JoystickHasEvents) and (axisLeftYMinus in JoystickHasEvents)));
end;

function TJoystickLayout.HasRightStick: Boolean;
begin
  Result :=
    (axisRightX  in JoystickHasEvents) and
    ((axisRightY in JoystickHasEvents) or
    ((axisRightYPlus in JoystickHasEvents) and (axisRightYMinus in JoystickHasEvents)));
end;

function TJoystickLayout.HasDPad: Boolean;
begin
  Result :=
    (dpadLeft in JoystickHasEvents) and
    (dpadRight in JoystickHasEvents) and
    (dpadUp in JoystickHasEvents) and
    (dpadDown in JoystickHasEvents);
end;

function TJoystickLayout.HasAbyx: Boolean;
begin
  Result :=
    (padX in JoystickHasEvents) and
    (padY in JoystickHasEvents) and
    (padA in JoystickHasEvents) and
    (padB in JoystickHasEvents);
end;

function TJoystickLayout.LogJoystickFeatures: String;
var
  J: TJoystickEvent;
  LogFeature: Boolean;
begin
  Result := 'Joystick "' + JoystickName + '" has the following features:' + NL;
  Result += 'GUID: ' + Guid + NL;
  if BuggyGuid then
    Result += 'This joystick GUID is known to be shared by different joyticks with different layouts' + NL;
  if BuggyDuplicateEvents then
    Result += 'The database for this joystick contains duplicate events, which makes mapping unreliable.' + NL;
  if BuggyDuplicateAxes then
    Result += 'The database for this joystick contains contradictive axes records, which makes mapping unreliable.' + NL;
  for J in TJoystickEvent do
    begin
      case J of
        unknownEvent, unknownAxisEvent, unknownButtonEvent: LogFeature := false;
        axisLeftXPlus, axisLeftXMinus: LogFeature := (not (axisLeftX in JoystickHasEvents));
        axisLeftYPlus, axisLeftYMinus: LogFeature := (not (axisLeftY in JoystickHasEvents));
        axisRightYPlus, axisRightYMinus: LogFeature := (not (axisRightY in JoystickHasEvents));
        else
          LogFeature := true;
      end;

      { Normally this should never ever happen, however, if we still encounter
        such a record, we shall try to mark it as "BUGGY" in the log }
      if (not LogFeature) and (J in JoystickHasEvents) then
      begin
        LogFeature := true;
        Result += '[BUGGY] ';
      end;

      if LogFeature then
        Result += JoystickEventToStr(J) + ': ' + (J in JoystickHasEvents).ToString(TUseBoolStrs.True) + NL;
    end;
end;

function JoystickEventToStr(const Event: TJoystickEvent): String;
begin
  WriteStr(Result, Event);
end;

end.

