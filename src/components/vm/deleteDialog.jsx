/*
 * This file is part of Cockpit.
 *
 * Copyright (C) 2017 Red Hat, Inc.
 *
 * Cockpit is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * Cockpit is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with Cockpit; If not, see <http://www.gnu.org/licenses/>.
 */

import cockpit from 'cockpit';
import React from 'react';
import {
    Button,
    DataList, DataListItem, DataListItemRow, DataListCheck, DataListItemCells, DataListCell,
    Form,
    Modal
} from '@patternfly/react-core';

import { vmId } from '../../helpers.js';
import { domainDelete } from '../../libvirtApi/domain.js';
import { snapshotDelete } from '../../libvirtApi/snapshot.js';
import { ModalError } from 'cockpit-components-inline-notification.jsx';

import './deleteDialog.css';

const _ = cockpit.gettext;

const DeleteDialogBody = ({ disks, destroy, onChange }) => {
    function disk_row(disk, index) {
        return (
            <DataListItem key={disk.target}
                          aria-labelledby={disk.target}>
                <DataListItemRow>
                    <DataListCheck
                            aria-labelledby={disk.target}
                            name={"check-action-" + disk.target}
                            onChange={checked => {
                                onChange(index, checked);
                            }}
                            checked={!!disk.checked} // https://github.com/patternfly/patternfly-react/issues/6762
                            isChecked={!!disk.checked} />
                    <DataListItemCells
                        dataListCells={[
                            <DataListCell id={disk.target} key="target name">
                                <strong>{disk.target}</strong>
                            </DataListCell>,
                            <DataListCell key="target source">
                                {disk.type == 'file' &&
                                <div className='disk-source'>
                                    <span> {_("Path")} </span>
                                    <strong className='disk-source-file'> {disk.source.file} </strong>
                                </div>}
                                {disk.type == 'volume' &&
                                <div className='disk-source'>
                                    <span htmlFor='disk-source-volume'> {_("Volume")} </span>
                                    <strong className='disk-source-volume'> {disk.source.volume} </strong>

                                    <span htmlFor='disk-source-pool'> {_("Pool")} </span>
                                    <strong className='disk-source-pool'> {disk.source.pool} </strong>
                                </div>}
                            </DataListCell>,
                        ]}
                    />
                </DataListItemRow>
            </DataListItem>
        );
    }

    let alert = null;
    if (destroy)
        alert = <p>{_("The VM is running and will be forced off before deletion.")}</p>;

    let disksBody = null;
    if (disks.length > 0)
        disksBody = (
            <Form onSubmit={e => e.preventDefault()}>
                <p>{_("Delete associated storage files:")}</p>
                <DataList isCompact>
                    { disks.map(disk_row) }
                </DataList>
            </Form>
        );

    return (
        <div className="modal-body">
            {alert}
            {disksBody}
        </div>
    );
};

export class DeleteDialog extends React.Component {
    constructor(props) {
        super(props);
        this.delete = this.delete.bind(this);
        this.onDiskCheckedChanged = this.onDiskCheckedChanged.bind(this);
        this.dialogErrorSet = this.dialogErrorSet.bind(this);

        const vm = props.vm;
        const disks = [];

        Object.keys(vm.disks).sort()
                .forEach(t => {
                    const d = vm.disks[t];

                    if ((d.type == 'file' && d.source.file) || d.type == 'volume')
                        disks.push(Object.assign(d, { checked: !d.readonly }));
                });
        this.state = { disks: disks };
    }

    dialogErrorSet(text, detail) {
        this.setState({ dialogError: text, dialogErrorDetail: detail });
    }

    onDiskCheckedChanged(index, value) {
        const disks = this.state.disks;

        disks[index].checked = value;
        this.setState(disks);
    }

    delete() {
        const storage = this.state.disks.filter(d => d.checked);
        const { vm, storagePools } = this.props;

        Promise.all(
            (Array.isArray(vm.snapshots) ? vm.snapshots : [])
                    .map(snapshot => snapshotDelete({ connectionName: vm.connectionName, domainPath: vm.id, snapshotName: snapshot.name }))
        )
                .then(() => domainDelete({ name: vm.name, id: vm.id, connectionName: vm.connectionName, options: { destroy: this.props.vm.state != 'shut off', storage: storage }, storagePools }))
                .then(() => cockpit.location.go(["vms"]))
                .catch(exc => {
                    this.dialogErrorSet(cockpit.format(_("VM $0 failed to get deleted"), vm.name), exc.message);
                });
    }

    render() {
        const id = vmId(this.props.vm.name);
        return (
            <Modal position="top" variant="medium" id={`${id}-delete-modal-dialog`} isOpen onClose={this.props.toggleModal}
                title={`Confirm deletion of ${this.props.vm.name}`}
                footer={
                    <>
                        {this.state.dialogError && <ModalError dialogError={this.state.dialogError} dialogErrorDetail={this.state.dialogErrorDetail} />}
                        <Button variant='danger' onClick={this.delete}>
                            {_("Delete")}
                        </Button>
                        <Button variant='link' className='btn-cancel' onClick={this.props.toggleModal}>
                            {_("Cancel")}
                        </Button>
                    </>
                }>
                <DeleteDialogBody disks={this.state.disks} destroy={this.props.vm.state != 'shut off'} onChange={this.onDiskCheckedChanged} />
            </Modal>
        );
    }
}
