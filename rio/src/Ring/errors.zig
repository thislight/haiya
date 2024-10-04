pub const RecvError = error{
    Again,
    BadF,
    ConnRefused,
    Fault,
    Intr,
    Inval,
    NotConn,
    NotSock,
    ConnReset,
};

pub const AcceptError = error{
    Again,
    BadF,
    NotSock,
    OpNotSupp,
    Fault,
    Perm,
    NoMem,
};

pub const SendError = error{
    BadF,
    NotSock,
    Fault,
    MsgSize,
    Again,
    NoBufs,
    Intr,
    NoMem,
    Inval,
    Pipe,
};

pub const CloseError = error{
    BadF,
    Intr,
    IO,
};

pub const CancelError = error{
    NoEnt,
    Inval,
    Already,
};
