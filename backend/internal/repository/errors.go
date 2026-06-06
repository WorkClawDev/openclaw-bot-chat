package repository

import "errors"

var ErrTaskUnavailable = errors.New("task is not available to claim")
