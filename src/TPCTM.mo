/**
 * Module     : TPCTM.mo v0.7
 * Author     : ICLighthouse Team
 * Stability  : Experimental
 * Description: ICTC 2PC Transaction Manager.
 * Refers     : https://github.com/iclighthouse/ICTC
 */

import Nat "mo:base/Nat";
import Array "mo:base/Array";
import Hash "mo:base/Hash";
import Option "mo:base/Option";
import Principal "mo:base/Principal";
import Time "mo:base/Time";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Deque "mo:base/Deque";
import TrieMap "mo:base/TrieMap";
import TA "./TA";

module {
    public let Version: Nat = 7;
    public type Toid = Nat;
    public type Ttid = TA.Ttid;
    public type Tcid = TA.Ttid;
    public type Callee = TA.Callee;
    public type CallType = TA.CallType;
    public type Receipt = TA.Receipt;
    public type Task = TA.Task;
    public type Status = TA.Status;
    public type Callback = TA.Callback;
    public type LocalCall = TA.LocalCall;
    public type TaskResult = TA.TaskResult;
    public type TaskEvent = TA.TaskEvent;
    public type ErrorLog = TA.ErrorLog;
    public type CalleeStatus = TA.CalleeStatus;
    public type Settings = {attemptsMax: ?TA.Attempts; recallInterval: ?Int; data: ?Blob};
    public type Phase = {#Prepare; #Commit; #Compensate;};
    public type PhaseResult = {#Yes; #No; #Doing; #None;};
    public type OrderStatus = {#Todo; #Preparing; #Committing; #Compensating; #Blocking; #Done; #Aborted;};  // *
    //public type CompStrategy = { #Forward; #Backward; };
    public type OrderCallback = (_toid: Toid, _status: OrderStatus, _data: ?Blob) -> async ();
    public type TaskRequest = {
        callee: Callee;
        callType: CallType;
        preTtid: [Ttid];
        attemptsMax: ?Nat;
        recallInterval: ?Int; // nanoseconds
        cycles: Nat;
        data: ?Blob;
    };
    public type TPCTask = {
        ttid: Ttid;
        prepare: Task;
        commit: Task;
        comp: ?Task; // for auto compensation
        status: Status;
    };
    public type TPCCommit = {
        ttid: Ttid;
        commit: Task;
        prepareTtid: Ttid;
        status: Status;
    };
    public type TPCCompensate = {
        forTtid: Ttid;
        tcid: Tcid;
        comp: Task;
        status: Status;
    };
    public type Order = {
        tasks: List.List<TPCTask>;
        commits: List.List<TPCCommit>;
        comps: List.List<TPCCompensate>;
        allowPushing: {#Opening; #Closed;};
        status: OrderStatus;  // *
        callbackStatus: ?Status;
        time: Time.Time;
        data: ?Blob;
    };
    public type Data = {
        autoClearTimeout: Int; 
        index: Nat; 
        firstIndex: Nat; 
        orders: [(Toid, Order)]; 
        aliveOrders: List.List<(Toid, Time.Time)>; 
        taskEvents: [(Toid, [Ttid])];
        actuator: TA.Data; 
    };

    public class TPCTM(this: Principal, localCall: LocalCall, defaultTaskCallback: ?Callback, defaultOrderCallback: ?OrderCallback) {
        let limitAtOnce: Nat = 20;
        var autoClearTimeout: Int = 3*30*24*3600*1000000000; // 3 months
        var index: Toid = 1;
        var firstIndex: Toid = 1;
        var orders = TrieMap.TrieMap<Toid, Order>(Nat.equal, Hash.hash);
        var aliveOrders = List.nil<(Toid, Time.Time)>();
        var taskEvents = TrieMap.TrieMap<Toid, [Ttid]>(Nat.equal, Hash.hash);
        var actuator_: ?TA.TA = null;
        var taskCallback = TrieMap.TrieMap<Ttid, Callback>(Nat.equal, Hash.hash);
        var commitCallbackTemp = TrieMap.TrieMap<Ttid, Callback>(Nat.equal, Hash.hash);
        var orderCallback = TrieMap.TrieMap<Toid, OrderCallback>(Nat.equal, Hash.hash);
        private func actuator() : TA.TA {
            switch(actuator_){
                case(?(_actuator)){ return _actuator; };
                case(_){
                    let act = TA.TA(limitAtOnce, autoClearTimeout, this, localCall, ?_taskCallbackProxy);
                    actuator_ := ?act;
                    return act;
                };
            };
            
        };

        // Unique callback entrance. This function will call each specified callback of task
        private func _taskCallbackProxy(_ttid: Ttid, _task: Task, _result: TaskResult) : async (){
            let toid = Option.get(_task.toid, 0);
            var orderStatus : OrderStatus = #Todo;
            var isClosed : Bool = false;
            switch(orders.get(toid)){
                case(?(order)){ 
                    orderStatus := order.status;
                    isClosed := order.allowPushing == #Closed;
                };
                case(_){};
            };
            // task status
            ignore _setTaskStatus(toid, _ttid, _result.0);
            // task callback
            switch(taskCallback.get(_ttid)){
                case(?(_taskCallback)){ 
                    await _taskCallback(_ttid, _task, _result); 
                    taskCallback.delete(_ttid);
                };
                case(_){
                    switch(defaultTaskCallback){
                        case(?(_taskCallback)){
                            await _taskCallback(_ttid, _task, _result);
                        };
                        case(_){};
                    };
                };
            };
            // process
            if (orderStatus == #Preparing){ //Preparing
                if (isClosed and _phaseResult(toid, #Prepare) == #Yes){ 
                    _setStatus(toid, #Committing);
                    _commit(toid);
                }else if (isClosed and _phaseResult(toid, #Prepare) == #No){ 
                    _setStatus(toid, #Compensating);
                    _compensate(toid);
                }else{ // Doing
                };
            } else if (orderStatus == #Committing){ //Committing
                if (isClosed and _phaseResult(toid, #Commit) == #Yes){ 
                    await _orderComplete(toid, #Done);
                    _removeTATaskByOid(toid);
                }else if (isClosed and _phaseResult(toid, #Commit) == #No){ 
                    _setStatus(toid, #Blocking);
                }else{ // Doing
                };
                // if (_result.0 == #Done and isClosed and Option.get(_orderLastCid(toid), 0) == _ttid){ 
                //     await _orderComplete(toid, #Recovered);
                //     _removeTATaskByOid(toid);
                // }else if (_result.0 == #Error or _result.0 == #Unknown){ //Blocking
                //     _setStatus(toid, #Blocking);
                // };
            } else if (orderStatus == #Compensating){ //Compensating 
                if (isClosed and _phaseResult(toid, #Compensate) == #Yes){ 
                    await _orderComplete(toid, #Aborted);
                    _removeTATaskByOid(toid);
                }else if (isClosed and _phaseResult(toid, #Compensate) == #No){ 
                    _setStatus(toid, #Blocking);
                }else{ // Doing
                };
                // if (_result.0 == #Done and isClosed and Option.get(_orderLastTid(toid), 0) == _ttid){ //
                //     await _orderComplete(toid, #Done);
                // }else if (_result.0 == #Error and strategy == #Backward){ // recovery
                //     _setStatus(toid, #Compensating);
                //     _compensate(toid, _ttid);
                // }else if (_result.0 == #Error or _result.0 == #Unknown){ //Blocking
                //     _setStatus(toid, #Blocking);
                // };
            } else { // Blocking
            };
            //taskEvents
            switch(taskEvents.get(toid)){
                case(?(events)){
                    taskEvents.put(toid, TA.arrayAppend(events, [_ttid]));
                };
                case(_){
                    taskEvents.put(toid, [_ttid]);
                };
            };
        };

        private func _phaseResult(_toid: Toid, _phase: Phase) : PhaseResult{ // Yes  Doing  No
            switch(orders.get(_toid)){
                case(?(order)){
                    switch(_phase){
                        case(#Prepare){
                            for (task in List.toArray(order.tasks).vals()){ 
                                if (task.status == #Error or task.status == #Unknown){
                                    return #No;
                                }else if (task.status == #Todo or task.status == #Doing){
                                    return #Doing;
                                };
                            };
                            return #Yes;
                        };
                        case(#Commit){
                            for (task in List.toArray(order.commits).vals()){ 
                                if (task.status == #Error or task.status == #Unknown){
                                    return #No;
                                }else if (task.status == #Todo or task.status == #Doing){
                                    return #Doing;
                                };
                            };
                            return #Yes;
                        };
                        case(#Compensate){
                            for (task in List.toArray(order.comps).vals()){ 
                                if (task.status == #Error or task.status == #Unknown){
                                    return #No;
                                }else if (task.status == #Todo or task.status == #Doing){
                                    return #Doing;
                                };
                            };
                            return #Yes;
                        };
                    };
                };
                case(_){ return #None; };
            };
        };

        // private functions
        private func _inOrders(_toid: Toid): Bool{
            return Option.isSome(orders.get(_toid));
        };
        private func _inAliveOrders(_toid: Toid): Bool{
            return Option.isSome(List.find(aliveOrders, func (item: (Toid, Time.Time)): Bool{ item.0 == _toid }));
        };
        private func _pushOrder(_toid: Toid, _order: Order): (){
            orders.put(_toid, _order);
            _clear(false);
        };
        private func _clear(_delExc: Bool) : (){
            var completed: Bool = false;
            var moveFirstPointer: Bool = true;
            var i: Nat = firstIndex;
            while (i < index and not(completed)){
                switch(orders.get(i)){
                    case(?(order)){
                        if (Time.now() > order.time + autoClearTimeout and (_delExc or order.status == #Done or order.status == #Aborted)){
                            _deleteOrder(i); // delete the record.
                            i += 1;
                        }else if (Time.now() > order.time + autoClearTimeout){
                            i += 1;
                            moveFirstPointer := false;
                        }else{
                            moveFirstPointer := false;
                            completed := true;
                        };
                    };
                    case(_){
                        i += 1;
                    };
                };
                if (moveFirstPointer) { firstIndex += 1; };
            };
        };
        private func _deleteOrder(_toid: Toid) : (){
            switch(orders.get(_toid)){
                case(?(order)){
                    orders.delete(_toid);
                    taskEvents.delete(_toid);
                };
                case(_){};
            };
        };

        private func _taskFromRequest(_toid: Toid, _forTtid: ?Ttid, _task: TaskRequest) : TA.Task{
            return {
                callee = _task.callee; 
                callType = _task.callType; 
                preTtid = _task.preTtid; 
                toid = ?_toid; 
                forTtid = _forTtid;
                attemptsMax = Option.get(_task.attemptsMax, 1); 
                recallInterval = Option.get(_task.recallInterval, 0); 
                cycles = _task.cycles;
                data = _task.data;
                time = Time.now();
            };
        };
        private func _compFromRequest(_toid: Toid, _forTtid: ?Ttid, _comp: ?TaskRequest) : ?Task{
            var comp: ?Task = null;
            switch(_comp){
                case(?(compensation)){
                    comp := ?{
                        callee = compensation.callee; 
                        callType = compensation.callType; 
                        preTtid = []; 
                        toid = ?_toid; 
                        forTtid = _forTtid;
                        attemptsMax = Option.get(compensation.attemptsMax, 1); 
                        recallInterval = Option.get(compensation.recallInterval, 0); 
                        cycles = compensation.cycles;
                        data = compensation.data;
                        time = Time.now();
                    }; 
                };
                case(_){};
            };
            return comp;
        };
        private func _orderLastTtid(_toid: Toid, _phase: Phase) : ?Ttid{
            switch(orders.get(_toid)){
                case(?(order)){
                    switch(_phase){
                        case(#Prepare){
                            switch(List.pop(order.tasks)){
                                case((?(task), ts)){
                                    return ?task.ttid;
                                };
                                case(_){ return null; };
                            };
                        };
                        case(#Commit){
                            switch(List.pop(order.commits)){
                                case((?(task), ts)){
                                    return ?task.ttid;
                                };
                                case(_){ return null; };
                            };
                        };
                        case(#Compensate){
                            switch(List.pop(order.comps)){
                                case((?(task), ts)){
                                    return ?task.tcid;
                                };
                                case(_){ return null; };
                            };
                        };
                    };
                };
                case(_){ return null; };
            };
        };
        private func _getCommitTtid(_toid: Toid, _prepareTtid: Ttid) : Ttid{
            switch(orders.get(_toid)){
                case(?(order)){
                    switch(List.find(order.commits, func (t:TPCCommit): Bool{ t.prepareTtid == _prepareTtid })){
                        case(?(commit)){ return commit.ttid; };
                        case(_){ return 0;  };
                    };
                };
                case(_){ return 0; };
            };
        };
        // private func _inOrderPrepares(_toid: Toid, _ttid: Ttid) : Bool{
        //     switch(orders.get(_toid)){
        //         case(?(order)){
        //             return Option.isSome(List.find(order.tasks, func (t:TPCTask): Bool{ t.ttid == _ttid }));
        //         };
        //         case(_){ return false; };
        //     };
        // };
        private func _putTask(_toid: Toid, _task: TPCTask) : (){
            switch(orders.get(_toid)){
                case(?(order)){
                    assert(order.allowPushing == #Opening);
                    let tasks = List.push(_task, order.tasks);
                    let orderNew = {
                        tasks = tasks;
                        commits = order.commits;
                        comps = order.comps;
                        allowPushing = order.allowPushing;
                        status = order.status;
                        callbackStatus = order.callbackStatus;
                        time = order.time;
                        data = order.data;
                    };
                    orders.put(_toid, orderNew);
                };
                case(_){};
            };
            if (_toid > 0 and not(_inAliveOrders(_toid))){
                aliveOrders := List.push((_toid, Time.now()), aliveOrders);
            };
        };
        private func _updateTask(_toid: Toid, _task: TPCTask) : (){
            switch(orders.get(_toid)){
                case(?(order)){
                    let tasks = List.map(order.tasks, func (t:TPCTask):TPCTask{
                        if (t.ttid == _task.ttid){ _task } else { t };
                    });
                    let orderNew = {
                        tasks = tasks;
                        commits = order.commits;
                        comps = order.comps;
                        allowPushing = order.allowPushing;
                        status = order.status;
                        callbackStatus = order.callbackStatus;
                        time = order.time;
                        data = order.data;
                    };
                    orders.put(_toid, orderNew);
                };
                case(_){};
            };
            if (_toid > 0 and not(_inAliveOrders(_toid))){
                aliveOrders := List.push((_toid, Time.now()), aliveOrders);
            };
        };
        
        private func _removeTask(_toid: Toid, _ttid: Ttid) : (){
            switch(orders.get(_toid)){
                case(?(order)){
                    let tasks = List.filter(order.tasks, func (t:TPCTask): Bool{ t.ttid != _ttid });
                    let orderNew = {
                        tasks = tasks;
                        commits = order.commits;
                        comps = order.comps;
                        allowPushing = order.allowPushing;
                        status = order.status;
                        callbackStatus = order.callbackStatus;
                        time = order.time;
                        data = order.data;
                    };
                    orders.put(_toid, orderNew);
                };
                case(_){};
            };
        };

        private func _removeTATaskByOid(_toid: Toid) : (){
            ignore actuator().removeByOid(_toid);
            switch(orders.get(_toid)){
                case(?(order)){
                    for (task in List.toArray(order.tasks).vals()){ 
                        taskCallback.delete(task.ttid);
                        commitCallbackTemp.delete(task.ttid);
                    };
                    for (task in List.toArray(order.commits).vals()){ 
                        taskCallback.delete(task.ttid);
                    };
                    for (task in List.toArray(order.comps).vals()){ 
                        taskCallback.delete(task.tcid);
                    };
                };
                case(_){};
            };
        };

        private func _isOpening(_toid: Toid) : Bool{
            switch(orders.get(_toid)){
                case(?(order)){ return order.allowPushing == #Opening };
                case(_){ return false; };
            };
        };
        private func _allowPushing(_toid: Toid, _setting: {#Opening; #Closed; }) : (){
            switch(orders.get(_toid)){
                case(?(order)){
                    let orderNew = {
                        tasks = order.tasks;
                        commits = order.commits;
                        comps = order.comps;
                        allowPushing = _setting;
                        status = order.status;
                        callbackStatus = order.callbackStatus;
                        time = order.time;
                        data = order.data;
                    };
                    orders.put(_toid, orderNew);
                };
                case(_){};
            };
        };
        private func _status(_toid: Toid) : ?OrderStatus{
            switch(orders.get(_toid)){
                case(?(order)){
                    return ?order.status;
                };
                case(_){ return null; };
            };
        };
        private func _statusEqual(_toid: Toid, _status: OrderStatus) : Bool{
            switch(orders.get(_toid)){
                case(?(order)){
                    return order.status == _status;
                };
                case(_){ return false; };
            };
        };
        private func _orderComplete(_toid: Toid, _tatus: OrderStatus) : async (){
            _setStatus(_toid, _tatus);
            var callbackStatus : ?Status = null;
            switch(orders.get(_toid)){
                case(?(order)){
                    for (task in List.toArray(order.tasks).vals()){ 
                        taskCallback.delete(task.ttid);
                        commitCallbackTemp.delete(task.ttid);
                    };
                    for (task in List.toArray(order.commits).vals()){ 
                        taskCallback.delete(task.ttid);
                    };
                    for (task in List.toArray(order.comps).vals()){ 
                        taskCallback.delete(task.tcid);
                    };
                    try{ 
                        switch(orderCallback.get(_toid)){
                            case(?(_orderCallback)){ 
                                await _orderCallback(_toid, _tatus, order.data); 
                                orderCallback.delete(_toid);
                                callbackStatus := ?#Done;
                            };
                            case(_){
                                switch(defaultOrderCallback){
                                    case(?(_orderCallback)){
                                        await _orderCallback(_toid, _tatus, order.data); 
                                        callbackStatus := ?#Done;
                                    };
                                    case(_){};
                                };
                            };
                        };
                    } catch(e) {
                        callbackStatus := ?#Error;
                    };
                    aliveOrders := List.filter(aliveOrders, func (item:(Toid, Time.Time)): Bool{ item.0 != _toid });
                };
                case(_){};
            };
            _setCallbackStatus(_toid, callbackStatus);
        };
        private func _setStatus(_toid: Toid, _setting: OrderStatus) : (){
            switch(orders.get(_toid)){
                case(?(order)){
                    let orderNew = {
                        tasks = order.tasks;
                        commits = order.commits;
                        comps = order.comps;
                        allowPushing = order.allowPushing;
                        status = _setting;
                        callbackStatus = order.callbackStatus;
                        time = order.time;
                        data = order.data;
                    };
                    orders.put(_toid, orderNew);
                };
                case(_){};
            };
        };
        private func _setCallbackStatus(_toid: Toid, _setting: ?Status) : (){
            switch(orders.get(_toid)){
                case(?(order)){
                    let orderNew = {
                        tasks = order.tasks;
                        commits = order.commits;
                        comps = order.comps;
                        allowPushing = order.allowPushing;
                        status = order.status;
                        callbackStatus = _setting;
                        time = order.time;
                        data = order.data;
                    };
                    orders.put(_toid, orderNew);
                };
                case(_){};
            };
        };
        private func _getTask(_toid: Toid, _ttid: Ttid) : ?TPCTask{
            switch(orders.get(_toid)){
                case(?(order)){
                    return List.find(order.tasks, func (t:TPCTask): Bool{ t.ttid == _ttid });
                };
                case(_){ return null; };
            };
        };
        private func _getCommit(_toid: Toid, _ttid: Ttid) : ?TPCCommit{
            switch(orders.get(_toid)){
                case(?(order)){
                    return List.find(order.commits, func (t:TPCCommit): Bool{ t.ttid == _ttid });
                };
                case(_){ return null; };
            };
        };
        private func _getComp(_toid: Toid, _tcid: Tcid) : ?TPCCompensate{
            switch(orders.get(_toid)){
                case(?(order)){
                    return List.find(order.comps, func (t:TPCCompensate): Bool{ t.tcid == _tcid });
                };
                case(_){ return null; };
            };
        };
        private func _isTasksDone(_toid: Toid) : Bool{
            return _phaseResult(_toid, #Prepare) == #Yes and _phaseResult(_toid, #Commit) == #Yes;
        };
        private func _isCompsDone(_toid: Toid) : Bool{
            return _phaseResult(_toid, #Compensate) == #Yes;
        };
        private func _statusTest(_toid: Toid) : async (){
            switch(orders.get(_toid)){
                case(?(order)){
                    if (order.status == #Committing and order.allowPushing == #Closed and _isTasksDone(_toid)){
                        await _orderComplete(_toid, #Done);
                    } else if (order.status == #Compensating and order.allowPushing == #Closed and _isCompsDone(_toid)){
                        await _orderComplete(_toid, #Aborted);
                        _removeTATaskByOid(_toid);
                    } else if (order.status == #Blocking and order.allowPushing == #Closed){
                        // Blocking
                    };
                };
                case(_){};
            };
        };
        private func _pushCommit(_toid: Toid, _ttid: Ttid, _commit: Task, _preTtid: ?[Ttid]) : Ttid{
            if (not(_inOrders(_toid))){ return 0; };
            //let preTtid = Option.get(_orderLastTtid(_toid, #Commit), 0);
            var preTtids: [Ttid] = [];
            //if (preTtid > 0){ preTtids := [preTtid]; };
            let task: Task = {
                callee = _commit.callee;
                callType = _commit.callType;
                preTtid = Option.get(_preTtid, preTtids);
                toid = _commit.toid;
                forTtid = ?_ttid;
                attemptsMax = _commit.attemptsMax;
                recallInterval = _commit.recallInterval;
                cycles = _commit.cycles;
                data = _commit.data;
                time = Time.now();
            };
            let cid = actuator().push(task);
            let commit: TPCCommit = {
                ttid = cid;
                commit = task;
                prepareTtid = _ttid;
                status = #Todo; //Todo
            };
            switch(orders.get(_toid)){
                case(?(order)){
                    let commits = List.push(commit, order.commits);
                    let orderNew = {
                        tasks = order.tasks;
                        commits = commits;
                        comps = order.comps;
                        allowPushing = order.allowPushing;
                        status = order.status;
                        callbackStatus = order.callbackStatus;
                        time = order.time;
                        data = order.data;
                    };
                    orders.put(_toid, orderNew);
                };
                case(_){};
            };
            return cid;
        };
        private func _commit(_toid: Toid) : (){
            switch(orders.get(_toid)){
                case(?(order)){
                    var tasks = order.tasks;
                    var item = List.pop(tasks);
                    while(Option.isSome(item.0)){
                        tasks := item.1;
                        switch(item.0){
                            case(?(task)){
                                let cid = _pushCommit(_toid, task.ttid, task.commit, null);
                                switch(commitCallbackTemp.get(task.ttid)){
                                    case(?(_commitCallback)){ 
                                        taskCallback.put(cid, _commitCallback);
                                        commitCallbackTemp.delete(task.ttid);
                                    };
                                    case(_){};
                                };
                            };
                            case(_){};
                        };
                        item := List.pop(tasks);
                    };
                };
                case(_){};
            };
        };
        // private func _orderLastCid(_toid: Toid) : ?Tcid{
        //     switch(orders.get(_toid)){
        //         case(?(order)){
        //             switch(List.pop(order.comps)){
        //                 case((?(comp), ts)){
        //                     return ?comp.tcid;
        //                 };
        //                 case(_){ return null; };
        //             };
        //         };
        //         case(_){ return null; };
        //     };
        // };
        // private func _inOrderComps(_toid: Toid, _tcid: Tcid) : Bool{
        //     switch(orders.get(_toid)){
        //         case(?(order)){
        //             return Option.isSome(List.find(order.comps, func (t:TPCCompensate): Bool{ t.tcid == _tcid }));
        //         };
        //         case(_){ return false; };
        //     };
        // };
        private func _pushComp(_toid: Toid, _ttid: Ttid, _comp: Task, _preTtid: ?[Ttid]) : Tcid{
            if (not(_inOrders(_toid))){ return 0; };
            //let preTtid = Option.get(_orderLastTtid(_toid, #Commit), 0);
            var preTtids: [Ttid] = [];
            //if (preTtid > 0){ preTtids := [preTtid]; };
            let task: Task = {
                callee = _comp.callee;
                callType = _comp.callType;
                preTtid = Option.get(_preTtid, preTtids);
                toid = _comp.toid;
                forTtid = ?_ttid;
                attemptsMax = _comp.attemptsMax;
                recallInterval = _comp.recallInterval;
                cycles = _comp.cycles;
                data = _comp.data;
                time = Time.now();
            };
            let cid = actuator().push(task);
            let compTask: TPCCompensate = {
                forTtid = _ttid;
                tcid = cid;
                comp = task;
                status = #Todo; //Todo
            };
            switch(orders.get(_toid)){
                case(?(order)){
                    let comps = List.push(compTask, order.comps);
                    let orderNew = {
                        tasks = order.tasks;
                        commits = order.commits;
                        comps = comps;
                        allowPushing = order.allowPushing;
                        status = order.status;
                        callbackStatus = order.callbackStatus;
                        time = order.time;
                        data = order.data;
                    };
                    orders.put(_toid, orderNew);
                };
                case(_){};
            };
            return cid;
        };
        private func _compensate(_toid: Toid) : (){
            switch(orders.get(_toid)){
                case(?(order)){
                    var tasks = order.tasks;
                    var item = List.pop(tasks);
                    while(Option.isSome(item.0)){
                        tasks := item.1;
                        switch(item.0){
                            case(?(task)){
                                if (task.status == #Done){
                                    switch(task.comp){
                                        case(?(comp)){
                                            let cid = _pushComp(_toid, task.ttid, comp, null);
                                        };
                                        case(_){ // ignore
                                        };
                                    };
                                };
                            };
                            case(_){};
                        };
                        item := List.pop(tasks);
                    };
                };
                case(_){};
            };
        };
        private func _setTaskStatus(_toid: Toid, _ttid: Ttid, _status: Status) : Bool{
            var res : Bool = false;
            switch(orders.get(_toid)){
                case(?(order)){
                    var tasks = order.tasks;
                    var commits = order.commits;
                    var comps = order.comps;
                    tasks := List.map(tasks, func (t:TPCTask): TPCTask{
                        if (t.ttid == _ttid){
                            res := true;
                            return {
                                ttid = t.ttid;
                                prepare = t.prepare;
                                commit = t.commit;
                                comp = t.comp;
                                status = _status;
                            };
                        } else { return t; };
                    });
                    commits := List.map(commits, func (t:TPCCommit): TPCCommit{
                        if (t.ttid == _ttid){
                            res := true;
                            return {
                                ttid = t.ttid;
                                commit = t.commit;
                                prepareTtid = t.prepareTtid;
                                status = _status;
                            };
                        } else { return t; };
                    });
                    comps := List.map(comps, func (t:TPCCompensate): TPCCompensate{
                        if (t.tcid == _ttid){
                            res := true;
                            return {
                                forTtid = t.forTtid;
                                tcid = t.tcid;
                                comp = t.comp;
                                status = _status;
                            };
                        } else { return t; };
                    });
                    let orderNew : Order = {
                        tasks = tasks;
                        commits = commits;
                        comps = comps;
                        allowPushing = order.allowPushing;
                        status = order.status;
                        callbackStatus = order.callbackStatus;
                        time = order.time;
                        data = order.data;
                    };
                    orders.put(_toid, orderNew);
                };
                case(_){};
            };
            return res;
        };
        private func __push(_toid: Toid, _prepare: TaskRequest, _commit: TaskRequest, _comp: ?TaskRequest) : Ttid {
            assert(_inOrders(_toid) and _isOpening(_toid));
            let prepare: TA.Task = _taskFromRequest(_toid, null, _prepare);
            let tid1 = actuator().push(prepare);
            let commit: TA.Task = _taskFromRequest(_toid, ?tid1, _commit);
            let comp = _compFromRequest(_toid, ?tid1, _comp);
            let tpcTask: TPCTask = {
                ttid = tid1;
                prepare = prepare;
                commit = commit;
                comp = comp;
                status = #Todo; //Todo
            };
            _putTask(_toid, tpcTask);
            return tid1;
        };

        // The following methods are used for transaction order operations.
        public func create(_data: ?Blob, _callback: ?OrderCallback) : Toid{
            assert(this != Principal.fromText("aaaaa-aa"));
            let toid = index;
            index += 1;
            let order: Order = {
                tasks = List.nil<TPCTask>();
                commits = List.nil<TPCCommit>();
                comps = List.nil<TPCCompensate>();
                allowPushing = #Opening;
                progress = #Completed(0);
                status = #Todo;
                callbackStatus = null;
                time = Time.now();
                data = _data;
            };
            _pushOrder(toid, order);
            switch(_callback){
                case(?(callback)){ orderCallback.put(toid, callback); };
                case(_){};
            };
            return toid;
        };
        public func push(_toid: Toid, _prepare: TaskRequest, _commit: TaskRequest, _comp: ?TaskRequest, 
        _prepareCallback: ?Callback, _commitCallback: ?Callback) : Ttid{
            let ttid = __push(_toid, _prepare, _commit, _comp);
            switch(_prepareCallback){
                case(?(callback)){ taskCallback.put(ttid, callback); };
                case(_){};
            };
            switch(_commitCallback){
                case(?(callback)){ commitCallbackTemp.put(ttid, callback); };
                case(_){};
            };
            return ttid;
        };
        public func open(_toid: Toid) : (){
            _allowPushing(_toid, #Opening);
        };
        public func finish(_toid: Toid) : (){
            _allowPushing(_toid, #Closed);
        };
        // public func isEmpty(_toid: Toid) : Bool{
        //     switch(orders.get(_toid)){
        //         case(?(order)){ List.size(order.tasks) == 0 };
        //         case(_){ true };
        //     };
        // };
        public func run(_toid: Toid) : async ?OrderStatus{
            switch(_status(_toid)){
                case(?(#Todo)){ _setStatus(_toid, #Preparing); };
                case(_){};
            };
            try{
                let count = await actuator().run();
            }catch(e){};
            await _statusTest(_toid);
            return _status(_toid);
        };

        // The following methods are used for queries.
        public func count() : Nat{
            return index - 1;
        };
        public func status(_toid: Toid) : ?OrderStatus{
            return _status(_toid);
        };
        public func isCompleted(_toid: Toid) : Bool{
            return _statusEqual(_toid, #Done);
        };
        public func isTaskCompleted(_ttid: Ttid) : Bool{
            return actuator().isCompleted(_ttid);
        };
        public func getOrder(_toid: Toid) : ?Order{
            return orders.get(_toid);
        };
        public func getOrders(_page: Nat, _size: Nat) : {data: [(Toid, Order)]; totalPage: Nat; total: Nat}{
            return TA.getTM<Order>(orders, index, firstIndex, _page, _size);
        };
        public func getAliveOrders() : [(Toid, ?Order)]{
            return Array.map<(Toid, Time.Time), (Toid, ?Order)>(List.toArray(aliveOrders), 
                func (item:(Toid, Time.Time)):(Toid, ?Order) { 
                    return (item.0, orders.get(item.0));
                });
        };
        public func getTaskEvents(_toid: Toid) : [TaskEvent]{
            var events: [TaskEvent] = [];
            for (tid in Option.get(taskEvents.get(_toid), []).vals()){
                let event_ =  actuator().getTaskEvent(tid);
                switch(event_){
                    case(?(event)) { events := TA.arrayAppend(events, [event]); };
                    case(_){};
                };
            };
            return events;
        };
        // public func getTaskEvent(_ttid: Ttid) : ?TaskEvent{
        //     return actuator().getTaskEvent(_ttid);
        // };
        // public func getAllEvents(_page: Nat, _size: Nat) : {data: [(Tid, TaskEvent)]; totalPage: Nat; total: Nat}{ 
        //     return actuator().getTaskEvents(_page, _size);
        // };
        public func getActuator() : TA.TA{
            return actuator();
        };
        

        // The following methods are used for clean up historical data.
        public func setCacheExpiration(_expiration: Int) : (){
            autoClearTimeout := _expiration;
        };
        public func clear(_delExc: Bool) : (){
            _clear(_delExc);
            actuator().clear(null, _delExc);
        };
        
        // The following methods are used for governance or manual compensation.
        /// update: Used to modify a task when blocking.
        public func update(_toid: Toid, _ttid: Ttid, _prepare: TaskRequest, _commit: TaskRequest, _comp: ?TaskRequest, 
        _prepareCallback: ?Callback, _commitCallback: ?Callback) : Ttid{
            assert(_inOrders(_toid) and _isOpening(_toid) and not(isCompleted(_toid)));
            assert(not(actuator().isCompleted(_ttid)));
            let prepare: TA.Task = _taskFromRequest(_toid, null, _prepare);
            let tid = actuator().update(_ttid, prepare);
            let commit = _taskFromRequest(_toid, ?tid, _commit);
            let comp = _compFromRequest(_toid, ?tid, _comp);
            let tpcTask: TPCTask = {
                ttid = tid;
                prepare = prepare;
                commit = commit;
                comp = comp;
                status = #Todo; //Todo
            };
            _updateTask(_toid, tpcTask);
            taskCallback.delete(tid);
            commitCallbackTemp.delete(tid);
            switch(_prepareCallback){
                case(?(callback)){ taskCallback.put(tid, callback); };
                case(_){};
            };
            switch(_commitCallback){
                case(?(callback)){ commitCallbackTemp.put(tid, callback); };
                case(_){};
            };
            return tid;
        };
        /// remove: Used to undo an unexecuted task.
        public func remove(_toid: Toid, _ttid: Ttid) : ?Ttid{
            assert(_inOrders(_toid) and _isOpening(_toid) and not(isCompleted(_toid)));
            assert(not(actuator().isCompleted(_ttid)));
            let tid_ = actuator().remove(_ttid);
            _removeTask(_toid, _ttid);
            taskCallback.delete(_ttid);
            commitCallbackTemp.delete(_ttid);
            return tid_;
        };
        
        /// append: Used to add a new task to an executing transaction order.
        public func append(_toid: Toid, _prepare: TaskRequest, _commit: TaskRequest, _comp: ?TaskRequest, 
        _prepareCallback: ?Callback, _commitCallback: ?Callback) : Ttid{
            assert(_inOrders(_toid) and _isOpening(_toid) and not(isCompleted(_toid)));
            let ttid = __push(_toid, _prepare, _commit, _comp);
            switch(_prepareCallback){
                case(?(callback)){ taskCallback.put(ttid, callback); };
                case(_){};
            };
            switch(_commitCallback){
                case(?(callback)){ commitCallbackTemp.put(ttid, callback); };
                case(_){};
            };
            return ttid;
        };
        public func appendComp(_toid: Toid, _forTtid: Ttid, _comp: TaskRequest, _callback: ?Callback) : Tcid{
            assert(_inOrders(_toid) and _isOpening(_toid) and not(isCompleted(_toid)));
            let comp = _taskFromRequest(_toid, ?_forTtid, _comp);
            let tcid = _pushComp(_toid, _forTtid, comp, ?comp.preTtid);
            switch(_callback){
                case(?(callback)){ taskCallback.put(tcid, callback); };
                case(_){};
            };
            return tcid;
        };
        /// complete: Used to change the status of a blocked order to completed.
        public func complete(_toid: Toid, _status: OrderStatus) : async Bool{
            assert(_status == #Done or _status == #Aborted);
            if (_statusEqual(_toid, #Blocking) and not(_isOpening(_toid)) and (_isTasksDone(_toid) or _isCompsDone(_toid))){
                await _orderComplete(_toid, _status);
                _removeTATaskByOid(_toid);
                return true;
            };
            return false;
        };

        // The following methods are used for data backup and reset.
        public func getData() : Data {
            return {
                autoClearTimeout = autoClearTimeout; 
                index = index; 
                firstIndex = firstIndex; 
                orders = Iter.toArray(orders.entries());
                aliveOrders = aliveOrders; 
                taskEvents = Iter.toArray(taskEvents.entries());
                //taskCallback = Iter.toArray(taskCallback.entries());
                //orderCallback = Iter.toArray(orderCallback.entries());
                actuator = actuator().getData(); 
            };
        };
        public func setData(_data: Data) : (){
            autoClearTimeout := _data.autoClearTimeout;
            index := _data.index; 
            firstIndex := _data.firstIndex; 
            orders := TrieMap.fromEntries(_data.orders.vals(), Nat.equal, Hash.hash);
            aliveOrders := _data.aliveOrders;
            taskEvents := TrieMap.fromEntries(_data.taskEvents.vals(), Nat.equal, Hash.hash);
            //taskCallback := TrieMap.fromEntries(_data.taskCallback.vals(), Nat.equal, Hash.hash);
            //orderCallback := TrieMap.fromEntries(_data.orderCallback.vals(), Nat.equal, Hash.hash);
            actuator().setData(_data.actuator);
        };
        

    };
};